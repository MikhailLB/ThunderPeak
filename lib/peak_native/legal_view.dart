import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Mini WebView used inside the native game menu for the legal pages
/// (Privacy Policy / Support). This is *not* the gray-flow arena; the
/// gray shell mounts `WebArena` instead.
///
/// Readability
/// -----------
/// The Privacy Policy page ships as bare HTML with default browser
/// styling — on a phone that renders as a wall of tiny black text
/// against white, wider than the viewport, with no gutters. We inject
/// a reading-mode CSS override on `onPageFinished` so the content
/// looks like a native reader: proper base font size, generous line
/// height, side gutters, and a comfortable text width. The user's
/// pinch-zoom still works because we only touch typography — never
/// the viewport meta.
class LegalView extends StatefulWidget {
  const LegalView({super.key, required this.title, required this.url});

  final String title;
  final String url;

  @override
  State<LegalView> createState() => _LegalViewState();
}

class _LegalViewState extends State<LegalView> {
  late final WebViewController _controller;
  bool _loading = true;

  static const String _readableCss = r'''
(function(){
  if (window.__tpReadable) return; window.__tpReadable = true;
  var ID = '__tp_readable_css';
  var css =
    'html,body{background:#FDFCF7!important;color:#141821!important;}' +
    'body{' +
      'margin:0!important;' +
      'padding:18px 20px 40px 20px!important;' +
      'font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif!important;' +
      'font-size:17px!important;' +
      'line-height:1.65!important;' +
      '-webkit-text-size-adjust:100%!important;' +
      'text-rendering:optimizeLegibility!important;' +
    '}' +
    'main,article,section,.content,.container,#content{max-width:680px!important;margin:0 auto!important;}' +
    'h1{font-size:28px!important;line-height:1.25!important;margin:20px 0 12px!important;color:#0E1220!important;font-weight:800!important;}' +
    'h2{font-size:21px!important;line-height:1.3!important;margin:26px 0 10px!important;color:#0E1220!important;font-weight:700!important;}' +
    'h3{font-size:18px!important;line-height:1.35!important;margin:22px 0 8px!important;color:#0E1220!important;font-weight:700!important;}' +
    'p,li,dd,dt{font-size:17px!important;line-height:1.65!important;color:#141821!important;}' +
    'strong,b{color:#0E1220!important;font-weight:700!important;}' +
    'a{color:#175FD1!important;text-decoration:underline!important;}' +
    'ul,ol{padding-left:22px!important;margin:8px 0 14px!important;}' +
    'li{margin:4px 0!important;}' +
    'hr{border:0!important;border-top:1px solid #D9D6CC!important;margin:26px 0!important;}' +
    'code,pre{background:#F1EEE4!important;color:#2A2F3B!important;border-radius:6px!important;padding:2px 6px!important;}' +
    'img{max-width:100%!important;height:auto!important;}';
  var head = document.head || document.documentElement;
  if (!head) return;
  var m = document.querySelector('meta[name="viewport"]');
  if (!m) {
    m = document.createElement('meta');
    m.setAttribute('name','viewport');
    m.setAttribute('content','width=device-width, initial-scale=1');
    head.appendChild(m);
  }
  var s = document.getElementById(ID);
  if (!s) { s = document.createElement('style'); s.id = ID; head.appendChild(s); }
  s.textContent = css;
})();
''';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFDFCF7))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (_) async {
            try {
              await _controller.runJavaScript(_readableCss);
            } catch (_) {}
            if (mounted) setState(() => _loading = false);
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Color(0xFF10214A),
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: const Color(0xFFFDFCF7),
        appBar: AppBar(
          title: Text(
            widget.title,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          backgroundColor: const Color(0xFF10214A),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        body: Stack(
          children: <Widget>[
            WebViewWidget(controller: _controller),
            if (_loading)
              const Center(
                child: CircularProgressIndicator(
                  color: Color(0xFFFFC93A),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
