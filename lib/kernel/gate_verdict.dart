// ============================================================
// GATE VERDICT — parsed reply from the config endpoint
// ============================================================
// Wire format from the backend is `{ ok, url, expires, message }`.
// The fields are renamed inside the app for readability, but the
// JSON keys are mapped verbatim so the backend contract is
// preserved exactly as documented in the gray-flow guide.
// ============================================================

class GateVerdict {
  const GateVerdict({
    required this.approved,
    this.contentUrl,
    this.remark,
    this.expiresAt,
  });

  /// `ok:true` → send the user to the WebView with [contentUrl].
  final bool approved;

  /// `url` — the URL to load in the WebView.
  final String? contentUrl;

  /// `message` — human-readable note (e.g. "organic", "geo blocked").
  final String? remark;

  /// `expires` — unix seconds after which [contentUrl] should be
  /// refreshed on a returning launch.
  final int? expiresAt;

  factory GateVerdict.fromMap(Map<String, dynamic> map) {
    return GateVerdict(
      approved: map['ok'] as bool? ?? false,
      contentUrl: map['url'] as String?,
      remark: map['message'] as String?,
      expiresAt: map['expires'] as int?,
    );
  }

  factory GateVerdict.rejected(String remark) =>
      GateVerdict(approved: false, remark: remark);

  bool get hasContent => contentUrl != null && contentUrl!.isNotEmpty;
}
