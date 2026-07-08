// ============================================================
// UA FORGE — outbound requests wear a real device user-agent
// ============================================================
// Both the HTTP client used by the gate/GCD/push image calls AND
// the WebView (`setUserAgent(...)`) share one forged UA string.
// A default Dart HTTP UA would be an instant fingerprint.
//
// The Chrome + WebKit fragments come out of the cipher, so the
// version string is never grep-able as plaintext in the APK. The
// Android release version reported by `device_info_plus` is a
// human-readable string (e.g. "14", "15") — never the SDK integer.
// This makes the UA look exactly like a real Chrome instance,
// which is the whole point.
//
// IDENTITY SUFFIX
// ---------------
// The template's `.cursor/rules/gray_user_agent.mdc` recommends
// appending `appid/<pkg> appname/<Name>` for slot themes, but for
// ThunderPeak the partner has explicitly asked for the plain UA —
// no identity suffix, either on the HTTP client or the WebView.
// The suffix is intentionally NOT emitted here; both surfaces read
// `_agent` verbatim.
// ============================================================

import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;

import '../config/locked_parcels.dart';

class MaskedHttp extends http.BaseClient {
  final http.Client _inner = http.Client();
  String _agent = 'Mozilla/5.0';

  String get agent => _agent;

  /// Reads device info and builds the composite UA. Call once from
  /// `main()` before any bridge is used.
  Future<void> prepare() async {
    final String chrome = _fallback(pluckChromeVersion(), '152.0.0.0');
    final String webkit = _fallback(pluckWebkitVersion(), '537.36');

    try {
      final DeviceInfoPlugin dev = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final AndroidDeviceInfo a = await dev.androidInfo;
        // NOTE: a.version.release is the marketing Android version
        // ("14", "15") — never the SDK int. This matches how a real
        // Chrome build advertises itself.
        final String buildTag = a.display.isNotEmpty ? a.display : a.id;
        _agent = 'Mozilla/5.0 (Linux; Android ${a.version.release}; '
            '${a.brand} ${a.model} Build/$buildTag) '
            'AppleWebKit/$webkit (KHTML, like Gecko) '
            'Chrome/$chrome Mobile Safari/$webkit';
      } else if (Platform.isIOS) {
        final IosDeviceInfo i = await dev.iosInfo;
        final String os = i.systemVersion.replaceAll('.', '_');
        _agent = 'Mozilla/5.0 (iPhone; CPU iPhone OS $os like Mac OS X) '
            'AppleWebKit/$webkit (KHTML, like Gecko) '
            'Version/${i.systemVersion} Mobile/15E148 Safari/$webkit';
      } else {
        _agent = _defaultUa(chrome, webkit);
      }
    } catch (_) {
      _agent = _defaultUa(chrome, webkit);
    }
  }

  static String _defaultUa(String chrome, String webkit) =>
      'Mozilla/5.0 (Linux; Android 15; Pixel 8 Build/AP4A.250505.011) '
      'AppleWebKit/$webkit (KHTML, like Gecko) '
      'Chrome/$chrome Mobile Safari/$webkit';

  static String _fallback(String value, String def) =>
      value.isEmpty ? def : value;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.putIfAbsent('User-Agent', () => _agent);
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

/// Shared client — every gray-flow HTTP call goes through this.
final MaskedHttp peakHttp = MaskedHttp();
