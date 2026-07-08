// ============================================================
// ROOT SHELL — MaterialApp wiring
// ============================================================
// Owns the long-lived wires and hands them down to the router.
// Title comes from the blueprint so it stays in sync with the
// Android app label and store listing.
//
// Root also installs the DEFAULT `BoltBeacon.onDeepLink` handler.
// When a warm push tap arrives while the user is on any screen
// that is not the WebView (menu / arena / offline / invite), the
// handler pushes a fresh `WebArena` on top through the shell's
// navigator key. `WebArena.initState` overrides the handler with
// its own live-load version and restores this default on dispose,
// so the routing always survives.
// ============================================================

import 'package:flutter/material.dart';

import '../config/peak_blueprint.dart';
import '../gray_veil/web_arena.dart';
import '../wires/bolt_beacon.dart';
import '../wires/peak_safe.dart';
import '../wires/signal_probe.dart';
import '../wires/trace_oracle.dart';
import '../wires/verdict_relay.dart';
import 'ascent_router.dart';

class RootShell extends StatefulWidget {
  const RootShell({
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
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    widget.beacon.onDeepLink = _handleGlobalDeepLink;
  }

  @override
  void dispose() {
    // Only clear if we still own the slot (WebArena may have taken it).
    if (widget.beacon.onDeepLink == _handleGlobalDeepLink) {
      widget.beacon.onDeepLink = null;
    }
    super.dispose();
  }

  void _handleGlobalDeepLink(String link) {
    final NavigatorState? nav = _navKey.currentState;
    if (nav == null) return;
    nav.pushReplacement(
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

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navKey,
      title: PeakBlueprint.displayName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFFD24C),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: AscentRouter(
        safe: widget.safe,
        probe: widget.probe,
        oracle: widget.oracle,
        relay: widget.relay,
        beacon: widget.beacon,
      ),
    );
  }
}
