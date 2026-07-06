import 'package:flutter/material.dart';

import 'game_screen.dart';
import 'webview_screen.dart';

class MainMenu extends StatelessWidget {
  const MainMenu({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/Background_OlympusTemple.webp',
            fit: BoxFit.cover,
          ),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.15),
                  Colors.black.withOpacity(0.55),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
              child: Column(
                children: [
                  const SizedBox(height: 16),
                  Expanded(
                    flex: 3,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Image.asset(
                          'assets/Game_Name.webp',
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 4,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _MenuButton(
                          label: 'PLAY',
                          icon: Icons.play_arrow_rounded,
                          primary: true,
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const GameScreen(),
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 16),
                        _MenuButton(
                          label: 'PRIVACY POLICY',
                          icon: Icons.privacy_tip_outlined,
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const WebViewScreen(
                                  title: 'Privacy Policy',
                                  url:
                                      'https://thunderrpeak.com/privacy-policy.html',
                                ),
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 12),
                        _MenuButton(
                          label: 'SUPPORT',
                          icon: Icons.support_agent_rounded,
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const WebViewScreen(
                                  title: 'Support',
                                  url: 'https://thunderrpeak.com/support.html',
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Tap and hold to charge lightning',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        letterSpacing: 1.2,
                      ),
                    ),
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

class _MenuButton extends StatefulWidget {
  const _MenuButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.primary = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool primary;

  @override
  State<_MenuButton> createState() => _MenuButtonState();
}

class _MenuButtonState extends State<_MenuButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final gradient = widget.primary
        ? const LinearGradient(
            colors: [Color(0xFFFFC93A), Color(0xFFFF6E3A)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          )
        : const LinearGradient(
            colors: [Color(0xFF203C7A), Color(0xFF10214A)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          );

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
            vertical: widget.primary ? 20 : 14,
            horizontal: 20,
          ),
          decoration: BoxDecoration(
            gradient: gradient,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Colors.white.withOpacity(widget.primary ? 0.9 : 0.4),
              width: widget.primary ? 2 : 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: (widget.primary
                        ? const Color(0xFFFFC93A)
                        : const Color(0xFF66E1FF))
                    .withOpacity(0.45),
                blurRadius: 18,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon, color: Colors.white, size: widget.primary ? 28 : 22),
              const SizedBox(width: 10),
              Text(
                widget.label,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: widget.primary ? 24 : 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.6,
                  shadows: const [
                    Shadow(blurRadius: 6, color: Colors.black45),
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
