// ============================================================
// PUSH INVITE STAGE — Accept / Skip promo
// ============================================================
// Shown once (respecting the reprompt cooldown) before the WebView.
// Accept fires the OS system dialog; Skip arms the cooldown.
// Either action forwards to the WebArena.
//
// Layout rules per TZ:
//   • Portrait  — buttons stacked with generous width, safe-area
//                 padded at the bottom.
//   • Landscape — SafeArea is intentionally OFF because the notch
//                 inset shifts the horizontal centre. Buttons use
//                 left:0/right:0 and Center() so they stay on the
//                 optical centre regardless of cutout.
// ============================================================

import 'package:flutter/material.dart';

import '../config/peak_art.dart';
import '../config/peak_blueprint.dart';
import '../wires/bolt_beacon.dart';
import '../wires/peak_safe.dart';
import '../wires/signal_probe.dart';
import 'bolt_pill.dart';
import 'web_arena.dart';

class PushInviteStage extends StatelessWidget {
  const PushInviteStage({
    super.key,
    required this.safe,
    required this.beacon,
    required this.probe,
    required this.contentUrl,
  });

  final PeakSafe safe;
  final BoltBeacon beacon;
  final SignalProbe probe;
  final String contentUrl;

  Future<void> _accept(BuildContext context) async {
    final bool granted = await beacon.requestPermission();
    if (!granted) {
      await safe.writeInviteCooldown(_cooldownTarget());
    }
    if (context.mounted) _forward(context);
  }

  Future<void> _skip(BuildContext context) async {
    await safe.writeInviteCooldown(_cooldownTarget());
    if (context.mounted) _forward(context);
  }

  int _cooldownTarget() =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000 +
      PeakBlueprint.inviteReprompt;

  void _forward(BuildContext context) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => WebArena(
          link: contentUrl,
          safe: safe,
          beacon: beacon,
          probe: probe,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final MediaQueryData mq = MediaQuery.of(context);
    final Size size = mq.size;
    final bool landscape = mq.orientation == Orientation.landscape;
    final String bg = landscape
        ? PeakArt.notifHorizontal
        : PeakArt.notifVertical;

    return Scaffold(
      backgroundColor: const Color(0xFF0B1930),
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Image.asset(
            bg,
            fit: BoxFit.cover,
            width: size.width,
            height: size.height,
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
          // NOTE: no SafeArea in landscape — see file header.
          Positioned(
            left: 0,
            right: 0,
            bottom: landscape ? size.height * 0.07 : size.height * 0.08,
            child: Center(
              child: landscape
                  // Landscape: BOTH pills identical (same tone, same
                  // width, same padding), sitting side-by-side and
                  // centered as a group. No SafeArea, so a camera
                  // cutout inset can never shift the group off-axis.
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        BoltPill(
                          label: 'Accept',
                          compact: true,
                          width: size.width * 0.24,
                          onTap: () => _accept(context),
                        ),
                        const SizedBox(width: 18),
                        BoltPill(
                          label: 'Skip',
                          compact: true,
                          width: size.width * 0.24,
                          onTap: () => _skip(context),
                        ),
                      ],
                    )
                  // Portrait: same primary gold tone on both pills for
                  // maximum WCAG contrast against dark artwork — user
                  // reads the choice by label + position, not colour.
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        BoltPill(
                          label: 'Accept',
                          width: size.width * 0.72,
                          onTap: () => _accept(context),
                        ),
                        const SizedBox(height: 14),
                        BoltPill(
                          label: 'Skip',
                          width: size.width * 0.72,
                          onTap: () => _skip(context),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
