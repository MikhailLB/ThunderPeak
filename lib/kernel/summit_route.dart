// ============================================================
// SUMMIT ROUTE — persisted mode for this install
// ============================================================
// - [gray]   → the last routing decision put us on the WebView.
// - [ascent] → the last routing decision put us on the native game.
// - [pending] → no decision yet (first launch, or storage cleared).
//
// The name is intentionally distinct from the template's `ShellMode`
// so identical dumps of prefs contents cannot be clustered across
// projects.
// ============================================================

enum SummitRoute {
  gray,
  ascent,
  pending;

  static SummitRoute decode(String? raw) {
    switch (raw) {
      case 'gray':
        return SummitRoute.gray;
      case 'ascent':
        return SummitRoute.ascent;
      default:
        return SummitRoute.pending;
    }
  }

  String encode() => name;
}
