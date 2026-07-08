// ============================================================
// LINK INTAKE — inbound VIEW-intent URI bridge
// ============================================================
// Talks to `MainActivity` over the `peak/route` MethodChannel and
// the `peak/route/events` EventChannel. Purpose: give the router
// access to the OneLink (or custom-scheme) URI that launched the
// app, WITHOUT relying on the AppsFlyer OneLink page or its
// server-side attribution.
//
// Why this exists: `thunderpeak.onelink.me` currently fails
// Android App Links verification (assetlinks.json returns 404 on
// AppsFlyer's edge) → Android silently drops our activity from
// the intent-chooser and every OneLink click ends up in Chrome.
// With `autoVerify` disabled in the manifest, our activity
// re-enters the chooser and the URI can reach us. When it does,
// the router synthesizes a Non-organic body from the URI's query
// params and hits /config.php directly, so the gray flow no
// longer depends on AppsFlyer's server working.
//
// [FINGERPRINT] Channel names and class names are project-unique.
// ============================================================

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class LinkIntake {
  LinkIntake._();

  static final LinkIntake instance = LinkIntake._();

  static const MethodChannel _method = MethodChannel('peak/route');
  static const EventChannel _events = EventChannel('peak/route/events');

  StreamSubscription<dynamic>? _sub;
  final StreamController<Uri> _onLink = StreamController<Uri>.broadcast();

  /// Emits every URI that reaches the activity while the app is
  /// alive (onNewIntent). Cold-launch URI is available via
  /// [pullInitial] instead.
  Stream<Uri> get onLink => _onLink.stream;

  /// Starts listening for onNewIntent URIs. Idempotent.
  void arm() {
    if (_sub != null) return;
    _sub = _events.receiveBroadcastStream().listen(
      (Object? raw) {
        final Uri? u = _tryParse(raw);
        if (u != null) {
          debugPrint('[GRAY][LINK] event → $u');
          _onLink.add(u);
        }
      },
      onError: (Object err) {
        debugPrint('[GRAY][LINK] event stream error: $err');
      },
    );
  }

  /// One-shot fetch of the URI that launched the app on this
  /// process instance. Returns null on a regular LAUNCHER intent.
  /// Consuming clears the native cache — the next call returns
  /// null unless a new onNewIntent arrives.
  Future<Uri?> pullInitial() async {
    try {
      final String? raw =
          await _method.invokeMethod<String>('getInitialLink');
      final Uri? u = _tryParse(raw);
      debugPrint('[GRAY][LINK] initial → ${u ?? '—'}');
      return u;
    } catch (e) {
      debugPrint('[GRAY][LINK] initial fetch error: $e');
      return null;
    }
  }

  Uri? _tryParse(Object? raw) {
    if (raw is! String) return null;
    if (raw.isEmpty) return null;
    try {
      return Uri.parse(raw);
    } catch (_) {
      return null;
    }
  }

  /// Returns true when [u] carries enough AppsFlyer campaign hints
  /// to justify a bypass — i.e. we can synthesize a Non-organic
  /// attribution body from its query params.
  ///
  /// Accepts:
  ///  * `https://<anything>.onelink.me/...?pid=...`
  ///  * `thunderpeak://open?pid=...` (custom-scheme redirect)
  ///  * Anything with any of pid / c / af_c_id / af_adset / adset
  ///    / siteid / deep_link_value / advertising_id in the query.
  static bool looksAttributed(Uri u) {
    final String scheme = u.scheme.toLowerCase();
    final String host = u.host.toLowerCase();
    final Map<String, String> q = u.queryParameters;
    final bool schemeOk = scheme == 'thunderpeak' ||
        (scheme == 'https' && host.endsWith('onelink.me'));
    if (!schemeOk) return false;
    const List<String> anchors = <String>[
      'pid',
      'c',
      'af_c_id',
      'af_adset',
      'adset',
      'siteid',
      'deep_link_value',
      'advertising_id',
      'shortlink',
    ];
    for (final String k in anchors) {
      final String? v = q[k];
      if (v != null && v.trim().isNotEmpty) return true;
    }
    return false;
  }
}
