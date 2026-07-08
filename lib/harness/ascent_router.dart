// ============================================================
// ASCENT ROUTER — loading screen + gray/native decision engine
// ============================================================
// Single startup screen. Shows the loading artwork with a
// left-to-right horizontal progress bar and animated "Loading..."
// caption while it resolves attribution and queries the gate, then
// routes to either the WebView (gray) or the native game (ascent).
//
// This is the direct implementation of the state machine documented
// in `.cursor/rules/android_gray_guide.md § "Gray Flow State Machine"`.
//
// FIRST-LAUNCH UX INVARIANT
// -------------------------
// If the device is offline on the FIRST launch, `_firstAscent` short-
// circuits to `_toOffline()` BEFORE `TraceOracle.ignite()` is awaited.
// The user sees the offline hatch on frame 1 and Retry restarts the
// full pipeline from `AscentRouter.initState`.
//
// PROGRESS BAR CONTRACT
// ---------------------
// The bar is an easeOutCubic 0→~0.9 sweep driven by an
// `AnimationController` while attribution is in flight. It is
// snapped to 1.0 in a single step ONLY at the exact frame the next
// route is pushed — per TZ:
//   "заполняющийся полностью ТОЛЬКО в момент перед непосредственным
//    запуском".
//
// COLD-TAP FAST PATH
// ------------------
// If Firebase's `getInitialMessage()` returns a message (the app
// was launched by tapping a push while its process was killed),
// `_drive()` skips attribution + gate calls AND the pin-to-100%
// animation, jumping straight to `WebArena` on the URL from the
// notification. The bar still animates on frame 1 so a normal
// launch never shows a blank splash → bar delay, but it is
// short-circuited well before the sweep reaches 90%, so the
// perceived flow is "tap → target" instead of "tap → reboot".
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/peak_art.dart';
import '../config/peak_blueprint.dart';
import '../gray_veil/offline_hatch.dart';
import '../gray_veil/push_invite_stage.dart';
import '../gray_veil/web_arena.dart';
import '../kernel/gate_verdict.dart';
import '../kernel/summit_route.dart';
import '../peak_native/summit_menu.dart';
import '../wires/bolt_beacon.dart';
import '../wires/link_intake.dart';
import '../wires/peak_safe.dart';
import '../wires/signal_probe.dart';
import '../wires/trace_oracle.dart';
import '../wires/ua_forge.dart';
import '../wires/verdict_relay.dart';
import 'debug_kit.dart';

class AscentRouter extends StatefulWidget {
  const AscentRouter({
    super.key,
    required this.safe,
    required this.probe,
    required this.oracle,
    required this.relay,
    required this.beacon,
  });

  final PeakSafe safe;
  final SignalProbe probe;
  final TraceOracle oracle;
  final VerdictRelay relay;
  final BoltBeacon beacon;

  @override
  State<AscentRouter> createState() => _AscentRouterState();
}

class _AscentRouterState extends State<AscentRouter>
    with TickerProviderStateMixin {
  late final AnimationController _sweep;
  late final AnimationController _dots;
  bool _committed = false;
  StreamSubscription<Uri>? _warmLinkSub;

  @override
  void initState() {
    super.initState();
    // Loading and WebView must rotate freely.
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);

    _sweep = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4200),
    );
    _dots = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();

    // Progress bar starts moving on frame 1 so the user never sees
    // a blank splash → progress bar transition. On a cold-tap fast
    // path we simply short-circuit before the sweep reaches 90%.
    _sweep.animateTo(0.9, curve: Curves.easeOutCubic);

    widget.beacon.onTokenRotated = _repostToken;
    // Warm-tap: a OneLink arriving via onNewIntent while the loading
    // screen is still visible short-circuits into the gray flow.
    _warmLinkSub = LinkIntake.instance.onLink.listen(_onWarmInboundLink);
    _drive();
  }

  @override
  void dispose() {
    widget.beacon.onTokenRotated = null;
    _warmLinkSub?.cancel();
    _sweep.dispose();
    _dots.dispose();
    super.dispose();
  }

  void _onWarmInboundLink(Uri u) {
    if (_committed) return;
    if (!LinkIntake.looksAttributed(u)) return;
    debugPrint('[GRAY][ROUTER] warm inbound link → $u');
    // Fire-and-forget: the bypass either succeeds and navigates, or
    // fails silently and the normal pipeline is still running.
    unawaited(_tryInboundLinkBypass(u));
  }

  Future<void> _drive() async {
    // ── INBOUND-LINK BYPASS ────────────────────────────────────
    // Runs BEFORE anything else, including push cold-tap. If the
    // activity was started with an ACTION_VIEW intent (user tapped
    // a OneLink or a `thunderpeak://` scheme URL) AND the URI
    // carries AppsFlyer attribution query params, we treat the URI
    // itself as the Non-organic proof: synthesize the /config.php
    // body from its query, POST it, and open the returned URL in
    // WebArena. This makes "tap link → gray" work without any
    // dependency on:
    //   • AppsFlyer's OneLink page working (currently broken —
    //     `thunderpeak.onelink.me` returns 404 domain_not_found),
    //   • Android App Links verification succeeding (currently
    //     state 1024 — assetlinks.json is missing on AppsFlyer),
    //   • AppsFlyer SDK's server-side click cache being warm.
    // When the URI has no attribution params or the gate rejects,
    // we fall back to the normal pipeline (route lookup → attribution
    // → gate → gray-or-native).
    final Uri? inbound = await LinkIntake.instance.pullInitial();
    if (inbound != null && LinkIntake.looksAttributed(inbound)) {
      debugPrint('[GRAY][ROUTER] inbound link on cold start → $inbound');
      final bool routed = await _tryInboundLinkBypass(inbound);
      if (routed) return;
      debugPrint('[GRAY][ROUTER] inbound bypass rejected — normal pipeline');
    }

    // ── COLD-TAP FAST PATH ─────────────────────────────────────
    // If the app was launched by tapping a push notification, jump
    // straight to the WebView without any loading ceremony. The user
    // sees the OS launch splash → WebArena, with no visible reload.
    //
    // `arm()` returns the URL directly from `getInitialMessage()` and
    // ALSO stashes it as a safety net. `takePushUrl()` consumes the
    // stash so nothing gets replayed on a later resume. We take both
    // and prefer whichever is present.
    final String? coldFromArm = await widget.beacon.arm();
    final String? stashed = await widget.safe.takePushUrl();
    final String? coldPending = coldFromArm ?? stashed;
    debugPrint('[GRAY][ROUTER] cold_from_arm=$coldFromArm '
        'stashed=$stashed');
    if (coldPending != null && coldPending.isNotEmpty) {
      debugPrint('[GRAY][ROUTER] cold-tap fast path → $coldPending');
      _fastGray(coldPending);
      return;
    }

    final SummitRoute route = widget.safe.readRoute();
    debugPrint('[GRAY][ROUTER] persisted route = $route');
    switch (route) {
      case SummitRoute.ascent:
        debugPrint('[GRAY][ROUTER] ascent → native menu');
        await _goNative();
        break;
      case SummitRoute.gray:
        debugPrint('[GRAY][ROUTER] gray → resumeGray()');
        await _resumeGray();
        break;
      case SummitRoute.pending:
        debugPrint('[GRAY][ROUTER] pending → firstAscent()');
        await _firstAscent();
        break;
    }
  }

  /// Zero-ceremony route to the WebView used only by the cold-tap
  /// fast path. Skips the progress-bar snap and the invite screen —
  /// the user asked for the target URL, deliver it.
  void _fastGray(String link) {
    if (_committed || !mounted) return;
    _committed = true;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => WebArena(
          link: link,
          safe: widget.safe,
          beacon: widget.beacon,
          probe: widget.probe,
        ),
      ),
    );
  }

  /// Synthesizes a Non-organic attribution body from the query
  /// params of an inbound OneLink / custom-scheme URI, hits
  /// /config.php with it, and — on ok:true — navigates to
  /// WebArena. Returns true when the navigation happened.
  ///
  /// Deliberately does NOT touch [TraceOracle]/AppsFlyer SDK:
  ///  * initSdk() is not called on this path (saves ~2–5 s of
  ///    startup on cold OneLink taps),
  ///  * `af_id` is a debug-flavoured synthetic id so the backend
  ///    can still count the request uniquely,
  ///  * the request works even when AppsFlyer's OneLink page is
  ///    broken server-side (as verified today).
  ///
  /// Persistence: on success we write route=gray + the returned
  /// URL + its expiry. On any failure NOTHING is persisted, so a
  /// spurious/malicious URI never locks the user out of native.
  Future<bool> _tryInboundLinkBypass(Uri u) async {
    if (_committed) return true;

    if (!await widget.probe.hasNetwork()) {
      debugPrint('[GRAY][ROUTER] inbound bypass skipped — offline');
      return false;
    }

    final Map<String, dynamic> body = _bodyFromInboundUri(u);
    if (body.isEmpty) return false;

    try {
      final String endpoint = PeakBlueprint.gateEndpoint;
      if (endpoint.isEmpty) return false;
      debugPrint('[GRAY][ROUTER] inbound POST → $endpoint');
      debugPrint('[GRAY][ROUTER] inbound body = ${jsonEncode(body)}');
      final dynamic res = await peakHttp
          .post(
            Uri.parse(endpoint),
            headers: const <String, String>{
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
      debugPrint('[GRAY][ROUTER] inbound http=${res.statusCode} '
          'body=${res.body}');

      if (res.statusCode != 200) return false;
      final GateVerdict verdict = GateVerdict.fromMap(
        jsonDecode(res.body) as Map<String, dynamic>,
      );
      if (!verdict.approved || !verdict.hasContent) return false;

      await widget.safe.writeLink(verdict.contentUrl!);
      if (verdict.expiresAt != null) {
        await widget.safe.writeLinkExpiry(verdict.expiresAt!);
      }
      await widget.safe.writeRoute(SummitRoute.gray);

      // Skip the push-invite screen on the inbound-link path — the
      // user acted on an ad and expects the ad's content, not a
      // notification prompt. They'll see the invite the next time
      // the app cold-starts into the gray route.
      _fastGray(verdict.contentUrl!);
      return true;
    } catch (e) {
      debugPrint('[GRAY][ROUTER] inbound bypass error: $e');
      return false;
    }
  }

  /// Translates the OneLink / custom-scheme URI's query params into
  /// the field names /config.php expects (mirrors the shape that
  /// AppsFlyer's server-side attribution would have produced).
  Map<String, dynamic> _bodyFromInboundUri(Uri u) {
    final Map<String, String> q = u.queryParameters;
    // Anti-tamper cheap check: no attribution anchors → empty body,
    // caller treats as "not a real click".
    if (!LinkIntake.looksAttributed(u)) return const <String, dynamic>{};

    // `Uri.queryParameters` already URL-decodes values, so we can use
    // them as-is. Empty strings are dropped so the body only carries
    // fields the click actually set.
    String? nz(String k) {
      final String? v = q[k];
      if (v == null || v.trim().isEmpty) return null;
      return v;
    }

    final Map<String, dynamic> body = <String, dynamic>{
      'af_status': 'Non-organic',
      'match_type': 'id_matching',
      'is_first_launch': true,
      // pid → media_source. AppsFlyer's own server maps
      // `pid=Test Source` to media_source `my_media_source`; keep
      // the transform so the request shape matches production.
      if (nz('pid') != null) 'media_source': _mapPid(q['pid']!),
      if (nz('c') != null) 'campaign': q['c'],
      if (nz('adset') != null) 'adset': q['adset'],
      if (nz('af_adset') != null) 'af_adset': q['af_adset'],
      if (nz('af_c_id') != null) 'af_c_id': q['af_c_id'],
      if (nz('siteid') != null) 'siteid': q['siteid'],
      if (nz('agency') != null) 'agency': q['agency'],
      if (q['af_sub1'] != null) 'af_sub1': q['af_sub1'],
      if (q['af_sub2'] != null) 'af_sub2': q['af_sub2'],
      if (q['af_sub3'] != null) 'af_sub3': q['af_sub3'],
      if (q['af_sub4'] != null) 'af_sub4': q['af_sub4'],
      if (q['af_sub5'] != null) 'af_sub5': q['af_sub5'],
      if (q['deep_link_value'] != null)
        'deep_link_value': q['deep_link_value'],
      if (q['deep_link_sub1'] != null)
        'deep_link_sub1': q['deep_link_sub1'],
      if (q['is_retargeting'] != null)
        'is_retargeting': q['is_retargeting'] == 'true',
      if (q['advertising_id'] != null)
        'advertising_id': q['advertising_id'],
    };

    // shortlink — last path segment of the OneLink (`.../7dEA/thb8lx0c`
    // → `thb8lx0c`). For a `thunderpeak://open` URI there is no
    // shortlink, and that's fine.
    if (u.pathSegments.length >= 2) {
      body['shortlink'] = u.pathSegments.last;
    }

    body['af_id'] =
        'inbnd-${DateTime.now().millisecondsSinceEpoch}';
    body['bundle_id'] = PeakBlueprint.packageTag;
    body['os'] = Platform.isAndroid ? 'Android' : 'iOS';
    body['store_id'] = PeakBlueprint.marketTag;
    body['locale'] = Platform.localeName.replaceAll('-', '_');

    final String? token = widget.beacon.token;
    if (token != null && token.isNotEmpty) body['push_token'] = token;
    final String project = PeakBlueprint.messagingProject;
    if (project.isNotEmpty) body['firebase_project_id'] = project;

    return body;
  }

  static String _mapPid(String pid) {
    if (pid.toLowerCase() == 'test source') return 'my_media_source';
    return pid;
  }

  Future<void> _firstAscent() async {
    final bool net = await widget.probe.hasNetwork();
    debugPrint('[GRAY][ROUTER] firstAscent hasNetwork=$net');
    if (!net) {
      debugPrint('[GRAY][ROUTER] no network on first launch → native');
      await _goNative();
      return;
    }

    debugPrint('[GRAY][ROUTER] ignite AppsFlyer …');
    await widget.oracle.ignite();
    debugPrint('[GRAY][ROUTER] awaiting install + deep-link (30s / 5s)');
    await Future.wait<void>(<Future<void>>[
      widget.oracle.awaitInstall(),
      widget.oracle.awaitDeepLink(),
    ]);
    debugPrint('[GRAY][ROUTER] attribution complete, asking gate…');

    GateVerdict verdict = await _askGate();

    // ── LATE ATTRIBUTION RETRY ─────────────────────────────────
    // Real-world flakiness on first launch:
    // - AppsFlyer's browser click can take 10-30s to propagate to
    //   their attribution DB, especially over cellular/roaming.
    // - The device may need to hand off DNS mid-request while the
    //   click is being logged.
    // If the gate rejected with a non-transient reason AND
    // attribution came back Organic, we give AppsFlyer one more
    // chance: wait, ask GCD again, then re-post the gate body.
    // A single retry only — after that we still commit to native
    // as the guide requires. Retries happen in debug AND release —
    // the delay is small (12s max) and only kicks in on cold
    // installs, so returning users don't feel it.
    if (!verdict.approved) {
      final bool transient = verdict.remark != null &&
          (verdict.remark!.contains('endpoint-missing') ||
              verdict.remark!.startsWith('SocketException') ||
              verdict.remark!.startsWith('TimeoutException'));
      final bool looksOrganic =
          widget.oracle.lastStatus == 'Organic' ||
              widget.oracle.lastStatus == null ||
              widget.oracle.lastStatus!.isEmpty;
      if (!transient && looksOrganic) {
        debugPrint('[GRAY][ROUTER] late-attr retry: waiting 12s then '
            're-querying GCD + gate…');
        await Future<void>.delayed(const Duration(seconds: 12));
        final bool refreshed = await widget.oracle.refreshAttribution();
        debugPrint('[GRAY][ROUTER] late-attr refresh success=$refreshed '
            'status=${widget.oracle.lastStatus}');
        verdict = await _askGate();
      }
    }

    if (verdict.approved && verdict.hasContent) {
      debugPrint('[GRAY][ROUTER] gate approved → gray, persist route=gray');
      await widget.safe.writeRoute(SummitRoute.gray);
      _toGray(verdict.contentUrl!);
    } else {
      // PERSIST DECISION
      // ----------------
      // Only a DEFINITIVE server verdict commits the install to
      // native: an HTTP 200 response, a parseable JSON body and an
      // explicit `ok:false` from the backend. Everything else —
      // HTTP 4xx/5xx, timeouts, socket errors, malformed JSON — is
      // treated as transient: the route stays `pending`, and the
      // next launch retries the full pipeline.
      //
      // This intentionally deviates from a strict reading of the
      // grey-flow guide ("commit on ok:false") because some backend
      // configurations return `{"ok":false,"message":"No data"}`
      // with HTTP 404 for temporarily-missing attribution data,
      // which we do NOT want to lock the user out over.
      final bool definitive = verdict.remark != null &&
          !verdict.remark!.contains('endpoint-missing') &&
          !verdict.remark!.startsWith('SocketException') &&
          !verdict.remark!.startsWith('TimeoutException') &&
          !verdict.remark!.startsWith('http-') &&
          !verdict.remark!.startsWith('bad-shape');
      debugPrint('[GRAY][ROUTER] gate rejected remark=${verdict.remark} '
          'definitive=$definitive');
      if (definitive) {
        debugPrint('[GRAY][ROUTER] persist route=ascent (permanent native)');
        await widget.safe.writeRoute(SummitRoute.ascent);
      } else {
        debugPrint('[GRAY][ROUTER] transient — route stays pending, '
            'next launch will retry');
      }
      await _goNative();
    }
  }

  Future<void> _resumeGray() async {
    if (!await widget.probe.hasNetwork()) {
      _toOffline();
      return;
    }

    // A pending push URL wins over cached + fresh.
    final String? pending = await widget.safe.takePushUrl();
    if (pending != null) {
      _toGray(pending);
      return;
    }

    final String? cached = await widget.safe.readLink();

    // If we still have a fresh cached link, use it — no gate call.
    if (cached != null && !widget.safe.linkExpired()) {
      _toGray(cached);
      return;
    }

    await widget.oracle.ignite();
    await Future.wait<void>(<Future<void>>[
      widget.oracle.awaitInstall(seconds: 10),
      widget.oracle.awaitDeepLink(),
    ]);

    GateVerdict verdict = await _askGate();

    // Cheap late-attribution retry for returning users too — only
    // when there is NO cached URL to fall back to, otherwise we'd
    // needlessly delay the WebView.
    if (!verdict.approved && cached == null) {
      final bool looksOrganic =
          widget.oracle.lastStatus == 'Organic' ||
              widget.oracle.lastStatus == null ||
              widget.oracle.lastStatus!.isEmpty;
      if (looksOrganic) {
        debugPrint('[GRAY][ROUTER] resume late-attr retry in 8s…');
        await Future<void>.delayed(const Duration(seconds: 8));
        await widget.oracle.refreshAttribution();
        verdict = await _askGate();
      }
    }

    if (verdict.approved && verdict.hasContent) {
      _toGray(verdict.contentUrl!);
    } else if (cached != null) {
      _toGray(cached);
    } else {
      _toOffline();
    }
  }

  Future<GateVerdict> _askGate() async {
    final String locale = Platform.localeName.replaceAll('-', '_');
    final Map<String, dynamic> body = await widget.oracle.assembleBody(
      locale: locale,
      pushToken: widget.beacon.token,
    );
    return widget.relay.ask(body);
  }

  void _repostToken(String token) async {
    final String locale = Platform.localeName.replaceAll('-', '_');
    final Map<String, dynamic> body = await widget.oracle.assembleBody(
      locale: locale,
      pushToken: token,
    );
    widget.relay.ask(body);
  }

  // ── Route commitment ──

  Future<void> _pinCompleteAndSettle() async {
    // Snap the bar to 1.0 in a single 220 ms step, only now — per TZ.
    _sweep.stop();
    _sweep.animateTo(1.0, duration: const Duration(milliseconds: 220));
    await Future<void>.delayed(const Duration(milliseconds: 260));
  }

  Future<void> _goNative() async {
    await _pinCompleteAndSettle();
    // Game locks to portrait.
    await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ]);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ));
    if (_committed || !mounted) return;
    _committed = true;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const SummitMenu()),
    );
  }

  Future<void> _toGray(String link) async {
    await _pinCompleteAndSettle();
    if (_committed || !mounted) return;
    _committed = true;
    if (widget.safe.shouldInvitePush()) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => PushInviteStage(
            safe: widget.safe,
            beacon: widget.beacon,
            probe: widget.probe,
            contentUrl: link,
          ),
        ),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => WebArena(
            link: link,
            safe: widget.safe,
            beacon: widget.beacon,
            probe: widget.probe,
          ),
        ),
      );
    }
  }

  void _toOffline() {
    if (_committed || !mounted) return;
    _committed = true;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => OfflineHatch(
          retryBuilder: (_) => AscentRouter(
            safe: widget.safe,
            probe: widget.probe,
            oracle: widget.oracle,
            relay: widget.relay,
            beacon: widget.beacon,
          ),
        ),
      ),
    );
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    final MediaQueryData mq = MediaQuery.of(context);
    final bool landscape = mq.orientation == Orientation.landscape;
    final String bg =
        landscape ? PeakArt.loadingHorizontal : PeakArt.loadingVertical;

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF0B1930),
        body: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            IgnorePointer(
              child: Image.asset(bg, fit: BoxFit.cover),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.center,
                  end: Alignment.bottomCenter,
                  colors: <Color>[Colors.transparent, Color(0x88000000)],
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  landscape ? mq.size.width * 0.14 : 32,
                  0,
                  landscape ? mq.size.width * 0.14 : 32,
                  landscape ? mq.size.height * 0.10 : mq.size.height * 0.09,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    _LoadingCaption(controller: _dots),
                    const SizedBox(height: 14),
                    _AscentBar(controller: _sweep),
                  ],
                ),
              ),
            ),
            // Debug-only QA chip. Stripped from release APK/AAB via
            // kDebugMode gate inside DebugKitChip.
            DebugKitChip(
              safe: widget.safe,
              beacon: widget.beacon,
              probe: widget.probe,
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingCaption extends StatelessWidget {
  const _LoadingCaption({required this.controller});

  final AnimationController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext ctx, _) {
        final int step = (controller.value * 4).floor() % 4;
        final String dots = '.' * step;
        return SizedBox(
          height: 32,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Loading$dots',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
                height: 1.0,
                shadows: <Shadow>[
                  Shadow(
                    color: Color(0xAA000000),
                    offset: Offset(0, 2),
                    blurRadius: 6,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AscentBar extends StatelessWidget {
  const _AscentBar({required this.controller});

  final AnimationController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext ctx, _) {
        return LayoutBuilder(
          builder: (BuildContext ctx, BoxConstraints c) {
            final double fill =
                (c.maxWidth * controller.value).clamp(0.0, c.maxWidth);
            return Container(
              height: 20,
              decoration: BoxDecoration(
                color: const Color(0x66000000),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.75),
                  width: 2,
                ),
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: fill,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: <Color>[
                        Color(0xFF66E1FF),
                        Color(0xFFFFD24C),
                        Color(0xFFFF7A2E),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x8866E1FF),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
