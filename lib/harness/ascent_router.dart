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
// `_drive()` skips both the attribution + gate calls AND the
// loading UI entirely, and mounts `WebArena` on the URL from the
// notification. The animation controllers are deliberately NOT
// started until the fast path is ruled out — this prevents the
// visible "reload" flash on OEMs that aggressively kill the
// backgrounded process.
// ============================================================

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/peak_art.dart';
import '../gray_veil/offline_hatch.dart';
import '../gray_veil/push_invite_stage.dart';
import '../gray_veil/web_arena.dart';
import '../kernel/gate_verdict.dart';
import '../kernel/summit_route.dart';
import '../peak_native/summit_menu.dart';
import '../wires/bolt_beacon.dart';
import '../wires/peak_safe.dart';
import '../wires/signal_probe.dart';
import '../wires/trace_oracle.dart';
import '../wires/verdict_relay.dart';

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
  // The loading artwork + progress bar is deferred until we know
  // the cold-tap fast path does NOT apply. On a push-launched cold
  // boot this prevents the "reload" flash the user reported.
  bool _showLoadingUi = false;

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
    );

    widget.beacon.onTokenRotated = _repostToken;
    _drive();
  }

  @override
  void dispose() {
    widget.beacon.onTokenRotated = null;
    _sweep.dispose();
    _dots.dispose();
    super.dispose();
  }

  Future<void> _drive() async {
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
    if (coldPending != null && coldPending.isNotEmpty) {
      // A push tap ALWAYS opens the gray URL regardless of the
      // persisted route — this is what the user tapped.
      _fastGray(coldPending);
      return;
    }

    // Reveal the loading UI now that we've ruled out the fast path,
    // and only now start the sweep + dots animations.
    if (mounted) {
      setState(() => _showLoadingUi = true);
      _dots.repeat();
      _sweep.animateTo(0.9, curve: Curves.easeOutCubic);
    }

    switch (widget.safe.readRoute()) {
      case SummitRoute.ascent:
        await _goNative();
        break;
      case SummitRoute.gray:
        await _resumeGray();
        break;
      case SummitRoute.pending:
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

  Future<void> _firstAscent() async {
    if (!await widget.probe.hasNetwork()) {
      // OFFLINE FIRST-LAUNCH CONTRACT (per TZ):
      // The white part must run without internet. There is NO
      // NoWifi hatch on the native path — a missing network on
      // first launch just routes into the game. We deliberately do
      // NOT persist `SummitRoute.ascent` here: if the device gains
      // internet later, the next launch can still run the full
      // attribution → gate pipeline and switch to gray if warranted.
      await _goNative();
      return;
    }

    await widget.oracle.ignite();
    await Future.wait<void>(<Future<void>>[
      widget.oracle.awaitInstall(),
      widget.oracle.awaitDeepLink(),
    ]);

    final GateVerdict verdict = await _askGate();
    if (verdict.approved && verdict.hasContent) {
      await widget.safe.writeRoute(SummitRoute.gray);
      _toGray(verdict.contentUrl!);
    } else {
      // Per gray-flow guide § "Behavior contract on failure":
      // ONLY a successful HTTP 200 response with `ok:false` may
      // permanently commit the install to native. Any transport
      // failure (DNS, timeout, socket) OR HTTP error (4xx/5xx) is
      // treated as retriable — otherwise a temporary server outage
      // on the very first launch would lock the user out of the
      // gray flow forever with no way to recover short of reinstall.
      //
      // `VerdictRelay.rejected(remark)` reports errors as:
      //   'endpoint-missing'  → config URL not set
      //   'http-<code>'       → non-2xx response
      //   '<Exception>: ...'  → transport error
      // A genuine ok:false lands here with remark = the message
      // string from the JSON body (or null) and NO `http-`/exception
      // prefix — that is the only case we permanent-commit.
      final String? r = verdict.remark;
      final bool isTransientHttp = r != null && r.startsWith('http-');
      final bool isTransport = r != null &&
          (r.contains('endpoint-missing') ||
              r.startsWith('SocketException') ||
              r.startsWith('TimeoutException') ||
              r.startsWith('HandshakeException') ||
              r.startsWith('HttpException') ||
              r.startsWith('ClientException') ||
              r.startsWith('FormatException'));
      if (!isTransientHttp && !isTransport) {
        await widget.safe.writeRoute(SummitRoute.ascent);
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

    final GateVerdict verdict = await _askGate();
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
            // Bar + caption are hidden during the cold-tap probe.
            // Everything below fades in once the router commits to the
            // normal (loading) pipeline.
            AnimatedOpacity(
              opacity: _showLoadingUi ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 180),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
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
                        landscape
                            ? mq.size.height * 0.10
                            : mq.size.height * 0.09,
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
                ],
              ),
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
