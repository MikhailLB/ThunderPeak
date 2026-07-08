// ============================================================
// DEBUG KIT — QA helpers, DEBUG BUILDS ONLY
// ============================================================
// Every entry point below is gated on `kDebugMode`. In release
// builds the compiler + tree-shaker strip the widget subtree and
// the MethodChannel calls become dead code, so the release APK/AAB
// does not carry any of this behavior. Never remove the guard.
//
// Purpose: make the AppsFlyer "click-before-install" test flow
// reproducible without a full `adb uninstall` + reinstall cycle.
//
// The flow the developer follows:
//   1) Long-press "DBG" chip on the loading screen (top-left).
//   2) Tap "Prepare test click".
//   3) Chrome opens with a real OneLink; AppsFlyer's servers see a
//      browser click for this device (GAID matches).
//   4) DebugKit calls ActivityManager.clearApplicationUserData() —
//      Android wipes SharedPreferences + secure storage + AppsFlyer
//      cache, then kills the process.
//   5) Developer relaunches the app manually. Fresh state, click on
//      file, SDK returns Non-organic, gate returns ok:true, gray.
// ============================================================

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/peak_blueprint.dart';
import '../kernel/summit_route.dart';
import '../wires/peak_safe.dart';

/// A OneLink hard-coded for QA use. Change here when the tester wants
/// to exercise a different campaign — this string never leaks into
/// release builds (the whole file is gated on kDebugMode).
const String kDebugOneLink =
    'https://thunderpeak.onelink.me/7dEA/thb8lx0c'
    '?pid=Test%20Source'
    '&c=testsub_testsub2_testsub_testsub_testsub_testsub_testsub_testsub1%20%23extra'
    '&siteid=syndicate_g&adset=testsub&af_adset=testsub3'
    '&af_c_id=testsub4&agency=Test%20Agency'
    '&af_sub1=testextra2&af_sub2=testextra3&af_sub3=testextra4'
    '&af_sub4=testextra5&af_sub5=testextra6'
    '&is_retargeting=true'
    '&deep_link_value=deep_link_test&deep_link_sub1=deep_test_sub1'
    '&advertising_id=2d6663b8-efe3-497f-908c-11d06e7b0c7b';

class DebugKit {
  DebugKit._();

  static const MethodChannel _dev = MethodChannel('peak/dev');

  static Future<bool> openInChrome(String url) async {
    if (!kDebugMode) return false;
    try {
      final bool? ok =
          await _dev.invokeMethod<bool>('open_in_chrome', <String, String>{
        'url': url,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Wipes all app data. Android kills the process synchronously after
  /// this call — nothing after it in Dart will run.
  static Future<void> clearAppData() async {
    if (!kDebugMode) return;
    try {
      await _dev.invokeMethod<bool>('clear_app_data');
    } catch (_) {}
  }
}

/// Tiny corner chip that reveals the debug bottom sheet. Add to any
/// screen you want to expose QA controls on — but only in debug mode.
class DebugKitChip extends StatelessWidget {
  const DebugKitChip({super.key, required this.safe});

  final PeakSafe safe;

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return const SizedBox.shrink();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(left: 8, top: 8),
        child: Align(
          alignment: Alignment.topLeft,
          child: Material(
            color: Colors.black.withValues(alpha: 0.55),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: Color(0xFFFFD24C), width: 1),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onLongPress: () => _openSheet(context),
              onTap: () => _openSheet(context),
              child: const Padding(
                padding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Text(
                  'DBG',
                  style: TextStyle(
                    color: Color(0xFFFFD24C),
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.4,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openSheet(BuildContext context) async {
    if (!kDebugMode) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF11213A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext ctx) => _DebugSheet(safe: safe),
    );
  }
}

class _DebugSheet extends StatefulWidget {
  const _DebugSheet({required this.safe});

  final PeakSafe safe;

  @override
  State<_DebugSheet> createState() => _DebugSheetState();
}

class _DebugSheetState extends State<_DebugSheet> {
  String? _cachedLink;
  int? _expiry;
  bool _pushGranted = false;
  bool _pushHardDenied = false;
  SummitRoute _route = SummitRoute.pending;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    _route = widget.safe.readRoute();
    _pushGranted = widget.safe.pushGranted();
    _pushHardDenied = widget.safe.pushHardDenied();
    _expiry = widget.safe.readLinkExpiry();
    _cachedLink = await widget.safe.readLink();
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        18,
        14,
        18,
        18 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Center(
              child: Container(
                width: 42,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text(
              'DebugKit — QA controls',
              style: TextStyle(
                color: Color(0xFFFFD24C),
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Debug builds only. This sheet is compiled out of release APK / AAB.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 16),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...<Widget>[
              _row('Persisted route', _route.toString().split('.').last),
              _row('Cached link',
                  _cachedLink != null ? _shortLink(_cachedLink!) : '—'),
              _row('Expires', _expiry != null ? _fmtExpiry(_expiry!) : '—'),
              _row('Push granted', _pushGranted ? 'yes' : 'no'),
              _row('Push hard-denied', _pushHardDenied ? 'yes' : 'no'),
              _row('AppsFlyer key set',
                  PeakBlueprint.attrKey.isNotEmpty ? 'yes' : 'no'),
              _row('Config endpoint',
                  PeakBlueprint.gateEndpoint.isEmpty
                      ? '—'
                      : _shortLink(PeakBlueprint.gateEndpoint)),
            ],
            const SizedBox(height: 20),
            _btn(
              icon: Icons.rocket_launch_rounded,
              label: 'Prepare test click (Chrome → wipe → relaunch)',
              subtitle:
                  'Opens the QA OneLink in Chrome, then clears all app data. '
                  'AppsFlyer registers a real browser click for this GAID; '
                  'relaunch manually to get Non-organic → gray.',
              onTap: () => _prepareTestClick(context),
            ),
            const SizedBox(height: 12),
            _btn(
              icon: Icons.public_rounded,
              label: 'Open QA OneLink in Chrome (no wipe)',
              subtitle: 'Registers a browser click without touching state.',
              onTap: () async {
                final bool ok = await DebugKit.openInChrome(kDebugOneLink);
                if (!context.mounted) return;
                _toast(context, ok ? 'Opened in Chrome' : 'Failed to open');
              },
            ),
            const SizedBox(height: 12),
            _btn(
              icon: Icons.delete_forever_rounded,
              label: 'Clear all app data & restart',
              subtitle: 'Kills the process, next launch starts from scratch.',
              destructive: true,
              onTap: () => _confirmAndClear(context),
            ),
            const SizedBox(height: 12),
            _btn(
              icon: Icons.link_off_rounded,
              label: 'Reset persisted route → pending',
              subtitle: 'Retries the gray-flow decision on next launch without '
                  'wiping AppsFlyer cache.',
              onTap: () async {
                await widget.safe.writeRoute(SummitRoute.pending);
                await _refresh();
                if (!context.mounted) return;
                _toast(context, 'Route reset to pending');
              },
            ),
            const SizedBox(height: 12),
            _btn(
              icon: Icons.refresh_rounded,
              label: 'Refresh',
              onTap: _refresh,
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 130,
              child: Text(label,
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 13)),
            ),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(
                    color: Colors.white, fontSize: 13, fontFamily: 'monospace'),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );

  Widget _btn({
    required IconData icon,
    required String label,
    String? subtitle,
    bool destructive = false,
    required VoidCallback onTap,
  }) {
    final Color fg = destructive ? const Color(0xFFFF7A6A) : Colors.white;
    final Color bg = destructive
        ? const Color(0x33FF3B30)
        : const Color(0x1AFFFFFF);
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(icon, color: fg, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(label,
                        style: TextStyle(
                            color: fg,
                            fontSize: 15,
                            fontWeight: FontWeight.w700)),
                    if (subtitle != null) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(subtitle,
                          style: const TextStyle(
                              color: Colors.white60, fontSize: 12)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _prepareTestClick(BuildContext context) async {
    final bool ok = await DebugKit.openInChrome(kDebugOneLink);
    if (!ok) {
      if (!context.mounted) return;
      _toast(context, 'Chrome not available');
      return;
    }
    // Give AppsFlyer 5 s to log the click, then wipe.
    await Future<void>.delayed(const Duration(seconds: 5));
    await DebugKit.clearAppData();
    // clearApplicationUserData kills the process — anything below
    // here will not execute. Kept intentionally as a safety net.
  }

  Future<void> _confirmAndClear(BuildContext context) async {
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        backgroundColor: const Color(0xFF11213A),
        title: const Text('Clear all data?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'This wipes SharedPreferences, secure storage, WebView cookies '
          'and AppsFlyer cache, then Android kills the process.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('Wipe',
                style: TextStyle(color: Color(0xFFFF7A6A))),
          ),
        ],
      ),
    );
    if (go == true) await DebugKit.clearAppData();
  }

  void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  static String _shortLink(String v) {
    if (v.length <= 48) return v;
    return '${v.substring(0, 24)}…${v.substring(v.length - 20)}';
  }

  static String _fmtExpiry(int unix) {
    final DateTime dt =
        DateTime.fromMillisecondsSinceEpoch(unix * 1000).toLocal();
    final int nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final int delta = unix - nowSec;
    final String rel = delta >= 0 ? 'in ${delta}s' : '${-delta}s ago';
    return '$dt  ($rel)';
  }
}
