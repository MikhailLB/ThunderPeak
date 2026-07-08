// ============================================================
// PEAK SAFE — persistence (prefs + secure storage)
// ============================================================
// SharedPreferences holds neutral flags (route mode, cooldowns,
// permission state). FlutterSecureStorage holds the sensitive
// URL blobs. Every key is deliberately opaque so a prefs dump
// yields no story about what the app is doing.
// ============================================================

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../kernel/summit_route.dart';

class PeakSafe {
  PeakSafe({FlutterSecureStorage? secure})
      : _crypt = secure ?? const FlutterSecureStorage();

  // Opaque key names (do not read like `webview_url` etc.).
  static const String _kRoute = 'pk_rt';
  static const String _kBlob = 'pk_bl';
  static const String _kEdge = 'pk_ex';
  static const String _kOffer = 'pk_of';
  static const String _kAllow = 'pk_al';
  static const String _kBanned = 'pk_bn';
  static const String _kPend = 'pk_pn';

  late final SharedPreferences _prefs;
  final FlutterSecureStorage _crypt;

  Future<void> preheat() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // ── Route mode ──
  SummitRoute readRoute() => SummitRoute.decode(_prefs.getString(_kRoute));

  Future<void> writeRoute(SummitRoute r) =>
      _prefs.setString(_kRoute, r.encode());

  // ── Cached content link (secure) ──
  Future<String?> readLink() => _crypt.read(key: _kBlob);
  Future<void> writeLink(String v) => _crypt.write(key: _kBlob, value: v);

  // ── Content link expiry ──
  int? readLinkExpiry() => _prefs.getInt(_kEdge);
  Future<void> writeLinkExpiry(int unixSec) => _prefs.setInt(_kEdge, unixSec);

  bool linkExpired() {
    final int? e = readLinkExpiry();
    if (e == null) return true;
    return _now() >= e;
  }

  // ── Push permission state ──
  bool pushGranted() => _prefs.getBool(_kAllow) ?? false;
  Future<void> setPushGranted(bool v) => _prefs.setBool(_kAllow, v);

  /// True once the OS denied the dialog — it can never be shown again,
  /// so the invite screen must stop trying.
  bool pushHardDenied() => _prefs.getBool(_kBanned) ?? false;
  Future<void> markPushHardDenied() => _prefs.setBool(_kBanned, true);

  int? readInviteCooldown() => _prefs.getInt(_kOffer);
  Future<void> writeInviteCooldown(int unixSec) =>
      _prefs.setInt(_kOffer, unixSec);

  /// Whether to show the invite screen before mounting the WebView.
  bool shouldInvitePush() {
    if (pushGranted()) return false;
    if (pushHardDenied()) return false;
    final int? until = readInviteCooldown();
    if (until == null) return true;
    return _now() >= until;
  }

  // ── One-shot push URL (secure) ──
  Future<void> stashPushUrl(String? link) async {
    if (link == null) {
      await _crypt.delete(key: _kPend);
    } else {
      await _crypt.write(key: _kPend, value: link);
    }
  }

  Future<String?> takePushUrl() async {
    final String? v = await _crypt.read(key: _kPend);
    if (v != null) await _crypt.delete(key: _kPend);
    return v;
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
}
