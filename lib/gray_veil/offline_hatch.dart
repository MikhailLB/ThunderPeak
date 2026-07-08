// ============================================================
// OFFLINE HATCH — no-connection screen
// ============================================================
// Uses the orientation-aware nowifi artwork. Retry rebuilds
// whatever screen the caller supplies (typically FlowRouter, or
// WebArena for in-session drops).
// ============================================================

import 'package:flutter/material.dart';

import '../config/peak_art.dart';
import 'bolt_pill.dart';

class OfflineHatch extends StatefulWidget {
  const OfflineHatch({super.key, required this.retryBuilder});

  final WidgetBuilder retryBuilder;

  @override
  State<OfflineHatch> createState() => _OfflineHatchState();
}

class _OfflineHatchState extends State<OfflineHatch> {
  bool _spinning = false;

  Future<void> _retry() async {
    if (_spinning) return;
    setState(() => _spinning = true);
    // Small settle delay so the user perceives a response before
    // the next screen boots.
    await Future<void>.delayed(const Duration(milliseconds: 550));
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: widget.retryBuilder),
    );
  }

  @override
  Widget build(BuildContext context) {
    final MediaQueryData mq = MediaQuery.of(context);
    final bool landscape = mq.orientation == Orientation.landscape;
    final Size size = mq.size;
    final String bg = landscape
        ? PeakArt.nowifiHorizontal
        : PeakArt.nowifiVertical;

    // Per TZ: landscape offline/notif screens must NOT wrap in
    // SafeArea — the safe insets can shift the horizontal centre
    // and misalign the button. We center the button horizontally
    // with left:0, right:0 and only add vertical padding.
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
                colors: <Color>[Colors.transparent, Color(0x99000000)],
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: landscape ? size.height * 0.09 : size.height * 0.08,
            child: Center(
              child: _spinning
                  ? const SizedBox(
                      width: 36,
                      height: 36,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Color(0xFFFFD24C)),
                      ),
                    )
                  : BoltPill(
                      label: 'Retry',
                      width: landscape
                          ? size.width * 0.32
                          : size.width * 0.62,
                      onTap: _retry,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
