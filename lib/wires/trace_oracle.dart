// ============================================================
// TRACE ORACLE — AppsFlyer attribution + deep-link collection
// ============================================================
// Collects the install-conversion payload, the deep-link click event
// and the app-open attribution. Callers merge these into the gate
// body according to the merge order in the gray-flow guide.
//
// Organic false-positive guard: on first launch, the SDK will
// occasionally report `af_status: "Organic"` for a truly paid
// install. When that happens we sleep [organicRecheckDelay] seconds
// and re-query the GCD endpoint for the real attribution.
//
// When the AppsFlyer dev key has not been provisioned yet, the
// bridge short-circuits with an empty payload so the shell does
// not stall waiting 30 s for a callback that can never fire.
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appsflyer_sdk/appsflyer_sdk.dart';
import 'package:flutter/foundation.dart';

import '../config/locked_parcels.dart';
import '../config/peak_blueprint.dart';
import 'ua_forge.dart';

class TraceOracle {
  AppsflyerSdk? _sdk;

  Map<String, dynamic>? _installFacts;
  Map<String, dynamic>? _deepLinkFacts;
  Map<String, dynamic>? _appOpenFacts;

  final Completer<Map<String, dynamic>> _installReady =
      Completer<Map<String, dynamic>>();
  final Completer<void> _deepLinkReady = Completer<void>();

  bool _lit = false;

  /// One-shot initialisation. Wires the SDK callbacks and returns as
  /// soon as init has been dispatched — the actual data lands on the
  /// completers.
  Future<void> ignite() async {
    if (_lit) return;
    _lit = true;

    final String devKey = PeakBlueprint.attrKey;
    if (devKey.isEmpty) {
      _finishInstall(<String, dynamic>{});
      _finishDeepLink();
      return;
    }

    final AppsFlyerOptions opts = AppsFlyerOptions(
      afDevKey: devKey,
      appId: PeakBlueprint.storeNumericId,
      showDebug: kDebugMode,
      timeToWaitForATTUserAuthorization: 10,
    );
    final AppsflyerSdk sdk = AppsflyerSdk(opts);
    _sdk = sdk;

    sdk.onInstallConversionData((dynamic raw) async {
      debugPrint('[GRAY][AF] conversion.raw = ${jsonEncode(raw)}');
      final Map<String, dynamic> payload = _flatten(raw);
      final String? status = payload['af_status']?.toString();
      debugPrint('[GRAY][AF] conversion.flat status=$status '
          'media_source=${payload['media_source']} '
          'campaign=${payload['campaign']} '
          'is_first=${payload['is_first_launch']} '
          'keys=${payload.keys.toList()}');
      if (status == 'Organic') {
        debugPrint('[GRAY][AF] status=Organic — recheck in '
            '${PeakBlueprint.organicRecheckDelay}s');
        await Future<void>.delayed(
          Duration(seconds: PeakBlueprint.organicRecheckDelay),
        );
        final Map<String, dynamic>? recheck = await _gcdRecheck();
        debugPrint('[GRAY][AF] gcd.recheck = ${jsonEncode(recheck)}');
        _installFacts = recheck ?? payload;
      } else {
        _installFacts = payload;
      }
      _finishInstall(_installFacts ?? <String, dynamic>{});
    });

    sdk.onAppOpenAttribution((dynamic raw) {
      debugPrint('[GRAY][AF] app_open.raw = ${jsonEncode(raw)}');
      _appOpenFacts = _flatten(raw);
    });

    sdk.onDeepLinking((DeepLinkResult res) {
      final Map<String, dynamic>? click = res.deepLink?.clickEvent;
      debugPrint('[GRAY][AF] deep_link status=${res.status} '
          'error=${res.error} '
          'click=${click != null ? jsonEncode(click) : '<null>'}');
      if (click != null) {
        _deepLinkFacts = Map<String, dynamic>.from(click);
      }
      _finishDeepLink();
    });

    try {
      debugPrint('[GRAY][AF] init dev_key=${devKey.substring(0, 4)}*** '
          'app_id=${PeakBlueprint.storeNumericId}');
      await sdk.initSdk(
        registerConversionDataCallback: true,
        registerOnAppOpenAttributionCallback: true,
        registerOnDeepLinkingCallback: true,
      );
      debugPrint('[GRAY][AF] initSdk() returned OK');
      final String? uid = await installUid();
      debugPrint('[GRAY][AF] appsflyer_uid=$uid');
    } catch (e, st) {
      debugPrint('[GRAY][AF] initSdk() threw: $e\n$st');
      _finishInstall(<String, dynamic>{});
      _finishDeepLink();
    }
  }

  Future<Map<String, dynamic>> awaitInstall({int seconds = 30}) {
    return _installReady.future.timeout(
      Duration(seconds: seconds),
      onTimeout: () => <String, dynamic>{},
    );
  }

  Future<void> awaitDeepLink() {
    return _deepLinkReady.future
        .timeout(const Duration(seconds: 5), onTimeout: () {});
  }

  /// Current AppsFlyer attribution status ("Organic", "Non-organic",
  /// or null when the SDK hasn't reported yet). Router reads this
  /// to decide whether a late-attribution retry is worth the wait.
  String? get lastStatus => _installFacts?['af_status']?.toString();

  /// Late-attribution retry: hits the GCD endpoint one more time and
  /// promotes the fresh payload into [_installFacts] if it changed
  /// the af_status away from Organic. Returns true when the caller
  /// should re-post the gate body.
  Future<bool> refreshAttribution() async {
    final Map<String, dynamic>? fresh = await _gcdRecheck();
    if (fresh == null || fresh.isEmpty) return false;
    final String? status = fresh['af_status']?.toString();
    // Merge — keep everything the SDK reported the first time, but
    // overwrite with anything GCD now knows about (media_source,
    // campaign, advertising_id, etc).
    final Map<String, dynamic> merged = <String, dynamic>{
      ...?_installFacts,
      ...fresh,
    };
    _installFacts = merged;
    return status != null && status != 'Organic';
  }

  Future<String?> installUid() async {
    if (_sdk == null) return null;
    try {
      return await _sdk!.getAppsFlyerUID();
    } catch (_) {
      return null;
    }
  }

  /// Builds the flat merged JSON body posted to the gate endpoint.
  /// Merge order (see gray-flow guide § "Request body — merge order"):
  ///   1) install facts (as-is)
  ///   2) deep-link facts (putIfAbsent)
  ///   3) app-open facts (putIfAbsent)
  ///   4) device-side fields (overwrite)
  Future<Map<String, dynamic>> assembleBody({
    required String locale,
    String? pushToken,
  }) async {
    final Map<String, dynamic> body = <String, dynamic>{};
    if (_installFacts != null) body.addAll(_installFacts!);
    _deepLinkFacts?.forEach(
      (String k, dynamic v) => body.putIfAbsent(k, () => v),
    );
    _appOpenFacts?.forEach(
      (String k, dynamic v) => body.putIfAbsent(k, () => v),
    );

    body['af_id'] = await installUid() ?? '';
    body['bundle_id'] = PeakBlueprint.packageTag;
    body['os'] = Platform.isAndroid ? 'Android' : 'iOS';
    body['store_id'] = PeakBlueprint.marketTag;
    body['locale'] = locale;

    if (pushToken != null && pushToken.isNotEmpty) {
      body['push_token'] = pushToken;
    }
    final String project = PeakBlueprint.messagingProject;
    if (project.isNotEmpty) {
      body['firebase_project_id'] = project;
    }

    debugPrint('[GRAY][BODY] to /config.php = ${jsonEncode(body)}');
    return body;
  }

  Future<Map<String, dynamic>?> _gcdRecheck() async {
    try {
      final String? uid = await installUid();
      if (uid == null) return null;
      final String appId = Platform.isIOS
          ? PeakBlueprint.storeNumericId
          : PeakBlueprint.packageTag;
      final String url = pluckGcdUrl(appId, uid);
      if (url.isEmpty) return null;

      final dynamic res = await peakHttp.get(
        Uri.parse(url),
        headers: <String, String>{
          'authorization': 'Bearer ${PeakBlueprint.attrKey}',
        },
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        return jsonDecode(res.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  void _finishInstall(Map<String, dynamic> data) {
    if (!_installReady.isCompleted) _installReady.complete(data);
  }

  void _finishDeepLink() {
    if (!_deepLinkReady.isCompleted) _deepLinkReady.complete();
  }

  static Map<String, dynamic> _flatten(dynamic raw) {
    if (raw is! Map) return <String, dynamic>{};
    final dynamic core = raw['payload'] ?? raw['data'] ?? raw;
    if (core is Map) {
      return core.map((dynamic k, dynamic v) => MapEntry<String, dynamic>(
            k.toString(),
            v,
          ));
    }
    return <String, dynamic>{};
  }
}
