// ============================================================
// PEAK ASSETS — asset paths for the gray shell
// ============================================================
// The shell backgrounds live in a fingerprinted addon folder so the
// literal path segment in the compiled APK differs from every other
// project. Game art paths are project-specific and are hard-coded
// inside `peak_native/*.dart`.
// ============================================================

class PeakArt {
  PeakArt._();

  // [FINGERPRINT] Rename this segment for every project.
  static const String _addon = 'assets/olympus_shell_pack';

  static const String loadingVertical = '$_addon/loading_vert.webp';
  static const String loadingHorizontal = '$_addon/loading_horz.webp';
  static const String notifVertical = '$_addon/notif_vert.webp';
  static const String notifHorizontal = '$_addon/notif_horz.webp';
  static const String nowifiVertical = '$_addon/nowifi_vert.webp';
  static const String nowifiHorizontal = '$_addon/nowifi_horz.webp';
}
