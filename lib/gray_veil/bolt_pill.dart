// ============================================================
// SHELL BUTTONS — gray-flow only
// ============================================================
// A single family of buttons for the gray-flow overlay stages
// (offline / push invite). Deliberately distinct from anything in
// the native game menu, and NOT gold-gradient (that colour is
// reserved for the game).
//
// PITFALLS ADDRESSED:
//   • Skip button is a real pill (§12 push_permission pitfall).
//   • Labels use `height: 1.0` + centered crossAxis alignment (§13).
// ============================================================

import 'package:flutter/material.dart';

/// Primary action pill — used for Accept / Retry.
class BoltPill extends StatefulWidget {
  const BoltPill({
    super.key,
    required this.label,
    required this.onTap,
    this.width,
    this.compact = false,
    this.tone = BoltTone.primary,
  });

  final String label;
  final VoidCallback onTap;
  final double? width;
  final bool compact;
  final BoltTone tone;

  @override
  State<BoltPill> createState() => _BoltPillState();
}

enum BoltTone { primary, secondary }

class _BoltPillState extends State<BoltPill> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final List<Color> gradient = widget.tone == BoltTone.primary
        ? const <Color>[Color(0xFFFFD24C), Color(0xFFFF7A2E)]
        : const <Color>[Color(0xFF3B6FD1), Color(0xFF1E3C7A)];

    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.95),
      onTapCancel: () => setState(() => _scale = 1.0),
      onTapUp: (_) {
        setState(() => _scale = 1.0);
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 90),
        child: Container(
          width: widget.width,
          padding: EdgeInsets.symmetric(
            horizontal: 26,
            vertical: widget.compact ? 12 : 16,
          ),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: gradient,
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            borderRadius: BorderRadius.circular(50),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.85),
              width: 2,
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: gradient.last.withValues(alpha: 0.55),
                offset: const Offset(0, 4),
                blurRadius: 14,
              ),
              const BoxShadow(
                color: Color(0x66000000),
                offset: Offset(0, 2),
                blurRadius: 6,
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Text(
                widget.label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: widget.compact ? 16 : 19,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                  height: 1.0,
                  shadows: const <Shadow>[
                    Shadow(
                      color: Color(0x66000000),
                      offset: Offset(0, 2),
                      blurRadius: 3,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
