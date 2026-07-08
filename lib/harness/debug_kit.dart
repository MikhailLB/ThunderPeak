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

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/peak_blueprint.dart';
import '../gray_veil/web_arena.dart';
import '../kernel/gate_verdict.dart';
import '../kernel/summit_route.dart';
import '../wires/bolt_beacon.dart';
import '../wires/peak_safe.dart';
import '../wires/signal_probe.dart';
import '../wires/ua_forge.dart';

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
    '&advertising_id=7d0d0acb-2603-4f89-8006-ac622ca4a505';

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

  /// Opens the OS "Open by default" screen for the ThunderPeak
  /// package. Available in BOTH debug and release builds — this is
  /// the fastest way to fix the "tap OneLink → Chrome instead of
  /// ThunderPeak" symptom on devices where AppsFlyer's Android
  /// App Links verification is failing (assetlinks.json 404).
  ///
  /// After the user toggles ON `thunderpeak.onelink.me` on that
  /// screen, every tap on a OneLink URL is delivered directly to
  /// MainActivity's ACTION_VIEW intent-filter and the router's
  /// inbound-link bypass fires → gray part launches, no chooser,
  /// no Chrome round-trip, no dependency on AppsFlyer's server.
  static Future<bool> openLinkDefaults() async {
    try {
      final bool? ok = await _dev.invokeMethod<bool>('open_link_defaults');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Parses a OneLink URL, synthesizes a Non-organic attribution body
  /// and asks `/config.php` for a content URL — bypassing AppsFlyer's
  /// server-side click tracking entirely.
  ///
  /// Useful when the OneLink itself is (temporarily) broken on
  /// AppsFlyer's side, or when there is no way to record a real
  /// browser click in the current test environment. The config
  /// server validates against the shape of the body, not against a
  /// real click on AppsFlyer, so this yields a real ok:true response
  /// with a real content URL when the campaign parameters look
  /// plausible.
  ///
  /// Persists route=gray + link + expiry on success. Returns the
  /// content URL, or null on any failure.
  static Future<String?> simulateOneLinkClick(
    String oneLinkUrl,
    PeakSafe safe, {
    String? pushToken,
  }) async {
    if (!kDebugMode) return null;

    final Uri parsed = Uri.parse(oneLinkUrl);
    final Map<String, String> q = parsed.queryParameters;

    // Translate the OneLink params to the AppsFlyer-attribution keys
    // that `/config.php` expects. `pid` → media_source, `c` →
    // campaign; everything with an `af_` prefix passes through
    // unchanged. Empty inputs are dropped so the body only carries
    // the fields the campaign actually set.
    final Map<String, dynamic> body = <String, dynamic>{
      'af_status': 'Non-organic',
      'match_type': 'id_matching',
      'is_first_launch': true,
      if (q['pid'] != null) 'media_source': _decodePidToMediaSource(q['pid']!),
      if (q['c'] != null) 'campaign': Uri.decodeComponent(q['c']!),
      if (q['adset'] != null) 'adset': q['adset'],
      if (q['af_adset'] != null) 'af_adset': q['af_adset'],
      if (q['af_c_id'] != null) 'af_c_id': q['af_c_id'],
      if (q['siteid'] != null) 'siteid': q['siteid'],
      if (q['agency'] != null) 'agency': Uri.decodeComponent(q['agency']!),
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
      // Match the shortlink (last path segment) so the server can
      // route the campaign through its usual pipeline.
      if (parsed.pathSegments.length >= 2)
        'shortlink': parsed.pathSegments.last,
      'af_id': 'dbg-${DateTime.now().millisecondsSinceEpoch}',
      'bundle_id': PeakBlueprint.packageTag,
      'os': Platform.isAndroid ? 'Android' : 'iOS',
      'store_id': PeakBlueprint.marketTag,
      'locale': Platform.localeName.replaceAll('-', '_'),
      if (pushToken != null && pushToken.isNotEmpty)
        'push_token': pushToken,
      if (PeakBlueprint.messagingProject.isNotEmpty)
        'firebase_project_id': PeakBlueprint.messagingProject,
    };

    debugPrint('[GRAY][DBG] simulateOneLinkClick body = ${jsonEncode(body)}');

    try {
      final dynamic res = await peakHttp
          .post(
            Uri.parse(PeakBlueprint.gateEndpoint),
            headers: const <String, String>{
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));

      debugPrint('[GRAY][DBG] simulateOneLinkClick http=${res.statusCode} '
          'body=${res.body}');

      if (res.statusCode != 200) return null;

      final GateVerdict verdict = GateVerdict.fromMap(
        jsonDecode(res.body) as Map<String, dynamic>,
      );
      if (!verdict.approved || !verdict.hasContent) return null;

      await safe.writeLink(verdict.contentUrl!);
      if (verdict.expiresAt != null) {
        await safe.writeLinkExpiry(verdict.expiresAt!);
      }
      await safe.writeRoute(SummitRoute.gray);
      return verdict.contentUrl;
    } catch (e) {
      debugPrint('[GRAY][DBG] simulateOneLinkClick error: $e');
      return null;
    }
  }

  /// `pid=Test Source` (URL-encoded) is what our successful real-click
  /// test received back from AppsFlyer server-side as
  /// `media_source: "my_media_source"`. Config.php happens to accept
  /// EITHER value, but keeping the same transform means the response
  /// looks identical to a real attribution.
  static String _decodePidToMediaSource(String pid) {
    final String decoded = Uri.decodeComponent(pid);
    if (decoded.toLowerCase() == 'test source') return 'my_media_source';
    return decoded;
  }
}

/// Tiny corner chip that reveals the debug bottom sheet. Add to any
/// screen you want to expose QA controls on — but only in debug mode.
class DebugKitChip extends StatelessWidget {
  const DebugKitChip({
    super.key,
    required this.safe,
    required this.beacon,
    required this.probe,
  });

  final PeakSafe safe;
  final BoltBeacon beacon;
  final SignalProbe probe;

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
      builder: (BuildContext ctx) => _DebugSheet(
        safe: safe,
        beacon: beacon,
        probe: probe,
      ),
    );
  }
}

class _DebugSheet extends StatefulWidget {
  const _DebugSheet({
    required this.safe,
    required this.beacon,
    required this.probe,
  });

  final PeakSafe safe;
  final BoltBeacon beacon;
  final SignalProbe probe;

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
              icon: Icons.settings_ethernet_rounded,
              label: 'Открыть системный экран "Open by default" 🔗',
              subtitle:
                  'Единственный способ заставить OS отдавать тапы по '
                  'OneLink нам, а не Chrome. На открывшемся экране '
                  'включи "Open supported links" и добавь '
                  '"thunderpeak.onelink.me". После этого тап по любой '
                  'OneLink-ссылке будет напрямую открывать серую часть.',
              onTap: () async {
                final bool ok = await DebugKit.openLinkDefaults();
                if (!context.mounted) return;
                _toast(
                  context,
                  ok
                      ? 'Открываю Settings — включи "Open supported links"'
                      : 'Failed to open Settings',
                );
              },
            ),
            const SizedBox(height: 12),
            _btn(
              icon: Icons.bolt_rounded,
              label: 'Simulate OneLink click → gray (bypass AppsFlyer)',
              subtitle:
                  'Parses the QA OneLink params, posts a synthesized '
                  'Non-organic body straight to /config.php and opens the '
                  'returned URL in the WebView. Use when the OneLink is '
                  'temporarily broken on AppsFlyer\'s side.',
              onTap: () => _simulateAndOpen(context),
            ),
            const SizedBox(height: 12),
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

  Future<void> _simulateAndOpen(BuildContext context) async {
    final NavigatorState rootNav = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext c) => const AlertDialog(
        backgroundColor: Color(0xFF11213A),
        content: Row(
          children: <Widget>[
            CircularProgressIndicator(),
            SizedBox(width: 18),
            Expanded(
              child: Text(
                'Asking /config.php with a synthesized Non-organic body…',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );

    final String? gray = await DebugKit.simulateOneLinkClick(
      kDebugOneLink,
      widget.safe,
      pushToken: widget.beacon.token,
    );

    if (!context.mounted) return;
    // Dismiss loader dialog.
    Navigator.of(context, rootNavigator: true).pop();

    if (gray == null) {
      _toast(context, 'Failed — check console for [GRAY][DBG] logs');
      return;
    }

    // Pop the debug bottom sheet, then replace the loading screen with
    // WebArena directly. This avoids a "restart the app" step for QA.
    Navigator.of(context).pop();
    rootNav.pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => WebArena(
          link: gray,
          safe: widget.safe,
          beacon: widget.beacon,
          probe: widget.probe,
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
