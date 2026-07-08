// ============================================================
// WEB ARENA — full-screen WebView for the gray flow
// ============================================================
// The core of the gray flow. Hosts the partner content link with:
//   • Forged device UA that matches `MaskedHttp.agent`.
//   • Both orientations, immersive system UI.
//   • Safe-area padding around the camera cutout on BOTH long and
//     short edges (landscape notch, portrait cutout).
//   • External-scheme hand-off (tel:, mailto:, market:, intent:).
//   • Redirect-loop recovery (up to 3 retries on the last main frame).
//   • Live connectivity guard — a `ConnectivityResult.none` sweep
//     jumps straight to the offline hatch (no DNS probe).
//   • WebView-level error handling: on DNS / disconnect errors we
//     cover the built-in WebView error page IMMEDIATELY with a
//     spinner so the user never sees the Android robot page.
//   • Warm push link routing — a live push replaces the current URL.
//   • File uploads through a MethodChannel to MainActivity.kt (no
//     file_picker dependency).
//   • Third-party cookies, inline autoplay video, DRM/EME auto-grant.
//   • Keyboard-scroll JS fix (single delayed pass, behavior:auto).
//   • Safe-area CSS neutraliser that ONLY touches top-padding on
//     known sticky headers — never `html/body/#app` (see
//     .cursor/rules/webview_safe_area_injection.mdc).
// ============================================================

import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../wires/bolt_beacon.dart';
import '../wires/peak_safe.dart';
import '../wires/signal_probe.dart';
import '../wires/ua_forge.dart';
import 'offline_hatch.dart';

class WebArena extends StatefulWidget {
  const WebArena({
    super.key,
    required this.link,
    required this.safe,
    required this.beacon,
    required this.probe,
  });

  final String link;
  final PeakSafe safe;
  final BoltBeacon beacon;
  final SignalProbe probe;

  @override
  State<WebArena> createState() => _WebArenaState();
}

class _WebArenaState extends State<WebArena> with WidgetsBindingObserver {
  // [FINGERPRINT] MethodChannel name — must match MainActivity.kt
  // exactly. Never reused between projects.
  static const MethodChannel _uploadChannel =
      MethodChannel('peak/attach');

  late final WebViewController _web;
  bool _showSpinner = true;
  bool _wentOffline = false;
  String? _lastMainFrame;
  int _redirectRetries = 0;
  Timer? _offlineDebounce;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  // Handler that owned the deep-link slot before this screen took it
  // over — restored on dispose so `RootShell`'s global handler keeps
  // routing warm taps once we're gone.
  void Function(String link)? _priorDeepLink;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _goImmersive();
    _buildController();

    _priorDeepLink = widget.beacon.onDeepLink;
    widget.beacon.onDeepLink = (String link) {
      if (!mounted) return;
      _web.loadRequest(Uri.parse(link));
    };

    _connSub = widget.probe.onChange.listen((List<ConnectivityResult> r) {
      final bool none = r.isNotEmpty &&
          r.every((ConnectivityResult e) => e == ConnectivityResult.none);
      if (none) {
        // Debounce VPN flicker; see pitfalls §3.
        _offlineDebounce?.cancel();
        _offlineDebounce = Timer(const Duration(milliseconds: 700), () {
          _openOffline();
        });
      } else {
        _offlineDebounce?.cancel();
      }
    });
  }

  void _goImmersive() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _goImmersive();
  }

  void _buildController() {
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(peakHttp.agent)
      ..setBackgroundColor(Colors.black)
      ..enableZoom(false)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          if (mounted) setState(() => _showSpinner = true);
        },
        onPageFinished: (String url) {
          if (mounted) setState(() => _showSpinner = false);
          _redirectRetries = 0;
          _neutraliseSafeAreaCss();
          _installKeyboardFix();
          _maybeReadableMode(url);
        },
        onWebResourceError: _onWebError,
        onNavigationRequest: _onNav,
      ));

    _tuneAndroid();
    _web.loadRequest(Uri.parse(widget.link));
  }

  void _onWebError(WebResourceError err) {
    if (err.isForMainFrame != true) return;
    final String desc = err.description.toLowerCase();

    final bool loop = desc.contains('too_many_redirects') ||
        desc.contains('too many redirects') ||
        err.errorCode == -1007 ||
        err.errorCode == -9;
    if (loop && _lastMainFrame != null && _redirectRetries < 3) {
      _redirectRetries++;
      _web.loadRequest(Uri.parse(_lastMainFrame!));
      return;
    }

    // Cover the WebView's built-in error page with our spinner
    // IMMEDIATELY, then decide whether to swap to offline.
    if (mounted) setState(() => _showSpinner = true);

    final bool dnsOrDrop = desc.contains('name_not_resolved') ||
        desc.contains('err_name_not_resolved') ||
        desc.contains('internet_disconnected') ||
        desc.contains('network_changed') ||
        err.errorCode == -105 ||
        err.errorCode == -106 ||
        err.errorCode == -21;
    if (dnsOrDrop) {
      _openOffline();
    } else {
      _guardOffline();
    }
  }

  NavigationDecision _onNav(NavigationRequest req) {
    final Uri? uri = Uri.tryParse(req.url);
    if (uri == null) return NavigationDecision.prevent;
    const Set<String> inline = <String>{
      'http',
      'https',
      'about',
      'data',
      'blob',
    };
    if (inline.contains(uri.scheme)) {
      if (req.isMainFrame) _lastMainFrame = req.url;
      return NavigationDecision.navigate;
    }
    _hopExternal(uri);
    return NavigationDecision.prevent;
  }

  void _tuneAndroid() {
    if (!Platform.isAndroid) return;
    if (_web.platform is! AndroidWebViewController) return;
    final AndroidWebViewController a =
        _web.platform as AndroidWebViewController;

    // Inline autoplay video.
    a.setMediaPlaybackRequiresUserGesture(false);

    // Auto-grant DRM / EME / mic / camera prompts — partner videos
    // and form fields expect these to work like a normal browser.
    a.setOnPlatformPermissionRequest(
      (PlatformWebViewPermissionRequest req) => req.grant(),
    );

    // Site's <input type="file"> — hand off to MainActivity.
    a.setOnShowFileSelector(_pickFiles);

    // Third-party cookies for OAuth / payment sessions.
    final AndroidWebViewCookieManager cookies = AndroidWebViewCookieManager(
      AndroidWebViewCookieManagerCreationParams
          .fromPlatformWebViewCookieManagerCreationParams(
        const PlatformWebViewCookieManagerCreationParams(),
      ),
    );
    cookies.setAcceptThirdPartyCookies(a, true);
  }

  Future<List<String>> _pickFiles(FileSelectorParams params) async {
    try {
      final List<Object?>? picked = await _uploadChannel
          .invokeMethod<List<Object?>>('pick', <String, Object>{
        'multiple': params.mode == FileSelectorMode.openMultiple,
        'mimeTypes': params.acceptTypes
            .where((String t) => t.trim().isNotEmpty)
            .toList(),
      });
      if (picked == null) return const <String>[];
      return picked.whereType<String>().toList();
    } catch (_) {
      return const <String>[];
    }
  }

  Future<void> _hopExternal(Uri uri) async {
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  // Used for transient WebView load errors — a real probe before
  // showing the offline screen.
  Future<void> _guardOffline() async {
    if (_wentOffline) return;
    final bool online = await widget.probe.hasNetwork();
    if (online) return;
    _openOffline();
  }

  void _openOffline() {
    if (_wentOffline || !mounted) return;
    _wentOffline = true;
    final String current = _lastMainFrame ?? widget.link;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => OfflineHatch(
          retryBuilder: (_) => WebArena(
            link: current,
            safe: widget.safe,
            beacon: widget.beacon,
            probe: widget.probe,
          ),
        ),
      ),
    );
  }

  // Keyboard-scroll fix — single delayed pass, behavior:'auto'.
  void _installKeyboardFix() {
    _web.runJavaScript(r'''
(function(){
  if (window.__pkKb) return; window.__pkKb = true;
  function isField(el){return el&&(el.tagName==='INPUT'||el.tagName==='TEXTAREA'||el.isContentEditable);}
  function bring(){
    var el=document.activeElement; if(!isField(el))return;
    var vp=window.visualViewport;
    if(vp){
      var r=el.getBoundingClientRect(); var bottom=vp.offsetTop+vp.height;
      if(r.bottom>bottom-20||r.top<vp.offsetTop){el.scrollIntoView({behavior:'auto',block:'nearest'});}
    } else { el.scrollIntoView({behavior:'auto',block:'nearest'}); }
  }
  document.addEventListener('focusin',function(e){ if(isField(e.target)) setTimeout(bring,350); });
  if(window.visualViewport){
    var prev=window.visualViewport.height;
    window.visualViewport.addEventListener('resize',function(){
      var h=window.visualViewport.height; if(h<prev) setTimeout(bring,120); prev=h;
    });
  }
})();
''');
  }

  // Safe-area CSS neutraliser.
  //
  // IMPORTANT: only overrides CSS variables and top-padding on known
  // header classes. NEVER touches padding-left/right on html/body/#app
  // (see .cursor/rules/webview_safe_area_injection.mdc — that pattern
  // squashes the partner site's own gutters).
  void _neutraliseSafeAreaCss() {
    _web.runJavaScript(r'''
(function(){
  if(window.__pkSa) return; window.__pkSa=true;
  var ID='__pk_sa';
  var CSS = ':root{'
    + '--safe-area-inset-top:0px!important;'
    + '--safe-area-inset-right:0px!important;'
    + '--safe-area-inset-bottom:0px!important;'
    + '--safe-area-inset-left:0px!important;'
    + '--sat:0px!important;--sar:0px!important;--sab:0px!important;--sal:0px!important;'
    + '--safe-top:0px!important;--safe-bottom:0px!important;'
    + '--safe-left:0px!important;--safe-right:0px!important;'
    + '}'
    + '.gameview-mobile-header,.app-header,.js-safe-top{padding-top:0!important;margin-top:0!important;}';
  function kbOpen(){ if(!window.visualViewport)return false; return window.visualViewport.height<window.innerHeight*0.75; }
  function apply(){
    if(kbOpen())return;
    var head=document.head||document.documentElement; if(!head)return;
    var m=document.querySelector('meta[name="viewport"]');
    if(m && !/viewport-fit\s*=\s*contain/i.test(m.getAttribute('content')||'')){
      var c=(m.getAttribute('content')||'').replace(/,?\s*viewport-fit\s*=\s*\w+/ig,'').trim();
      m.setAttribute('content', c + (c?', ':'') + 'viewport-fit=contain');
    }
    var s=document.getElementById(ID);
    if(!s){ s=document.createElement('style'); s.id=ID; head.appendChild(s); }
    if(s.textContent!==CSS) s.textContent=CSS;
  }
  apply();
  ['pushState','replaceState'].forEach(function(fn){
    var o=history[fn]; history[fn]=function(){var r=o.apply(this,arguments); setTimeout(apply,80); setTimeout(apply,400); return r;};
  });
  window.addEventListener('popstate',function(){setTimeout(apply,80);});
  setInterval(apply,2500);
})();
''');
  }

  // If the WebView lands on our own privacy-policy URL (e.g. because
  // the partner site links to it in its footer), apply the same
  // reading-mode CSS the native game's LegalView injects. The check
  // is a cheap substring match — the exact path lives in
  // `config/legal_links.dart`.
  void _maybeReadableMode(String url) {
    final String u = url.toLowerCase();
    if (!u.contains('privacy-policy') && !u.contains('privacy_policy')) {
      return;
    }
    _web.runJavaScript(r'''
(function(){
  if (window.__tpArenaReadable) return; window.__tpArenaReadable = true;
  var ID = '__tp_arena_readable';
  var css =
    'html,body{background:#FDFCF7!important;color:#141821!important;}' +
    'body{margin:0!important;padding:18px 20px 40px!important;' +
      'font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif!important;' +
      'font-size:17px!important;line-height:1.65!important;-webkit-text-size-adjust:100%!important;}' +
    'main,article,section,.content,.container,#content{max-width:680px!important;margin:0 auto!important;}' +
    'h1{font-size:28px!important;line-height:1.25!important;margin:20px 0 12px!important;font-weight:800!important;color:#0E1220!important;}' +
    'h2{font-size:21px!important;line-height:1.3!important;margin:26px 0 10px!important;font-weight:700!important;color:#0E1220!important;}' +
    'h3{font-size:18px!important;line-height:1.35!important;margin:22px 0 8px!important;font-weight:700!important;color:#0E1220!important;}' +
    'p,li,dd,dt{font-size:17px!important;line-height:1.65!important;color:#141821!important;}' +
    'a{color:#175FD1!important;text-decoration:underline!important;}' +
    'ul,ol{padding-left:22px!important;margin:8px 0 14px!important;}' +
    'hr{border:0!important;border-top:1px solid #D9D6CC!important;margin:26px 0!important;}';
  var head = document.head || document.documentElement;
  if (!head) return;
  var s = document.getElementById(ID);
  if (!s) { s = document.createElement('style'); s.id = ID; head.appendChild(s); }
  s.textContent = css;
})();
''');
  }

  Future<void> _stepBack() async {
    if (await _web.canGoBack()) {
      await _web.goBack();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _offlineDebounce?.cancel();
    _connSub?.cancel();
    // Hand the deep-link slot back to whoever owned it before us
    // (normally RootShell's global handler).
    widget.beacon.onDeepLink = _priorDeepLink;
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final MediaQueryData mq = MediaQuery.of(context);
    final bool landscape = mq.orientation == Orientation.landscape;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, _) async {
        if (!didPop) await _stepBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: false,
        body: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // SafeArea keeps the camera cutout inset in BOTH orientations
            // (top in portrait, side in landscape — see pitfalls §14).
            // Bottom is off because the keyboard is handled by JS scroll.
            SafeArea(
              bottom: false,
              child: WebViewWidget(controller: _web),
            ),
            if (_showSpinner && !landscape)
              const ColoredBox(
                color: Color(0x80000000),
                child: Center(
                  child: CircularProgressIndicator(
                    valueColor:
                        AlwaysStoppedAnimation<Color>(Color(0xFFFFD24C)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
