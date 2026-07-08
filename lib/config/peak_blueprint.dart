// ============================================================
// PEAK BLUEPRINT — app-wide identity and knobs
// ============================================================
// Single access point for identity + timing constants. Everything
// that could vary between projects lives in one place — a rename
// touches this file, `AndroidManifest.xml`, `build.gradle.kts` and
// the Kotlin package path, but nothing else.
// ============================================================

import 'legal_links.dart';
import 'locked_parcels.dart';

class PeakBlueprint {
  PeakBlueprint._();

  // ─────────────────────────────────────────────────────────
  // Identity
  // ─────────────────────────────────────────────────────────
  static const String packageTag = 'com.zeus.thunderpeak';
  static const String marketTag = 'com.zeus.thunderpeak';
  static const String displayName = 'ThunderPeak';

  // iOS App Store numeric id — unused on Android.
  static const String storeNumericId = '';

  // ─────────────────────────────────────────────────────────
  // Endpoints (resolved lazily via cipher — empty when secrets
  // have not yet been provisioned)
  // ─────────────────────────────────────────────────────────
  static String get gateEndpoint => pluckGateEndpoint();
  static String get attrKey => pluckAttrKey();
  static String get messagingProject => pluckMessagingProject();

  // ─────────────────────────────────────────────────────────
  // Legal / public
  // ─────────────────────────────────────────────────────────
  static const String privacyUrl = kPrivacyPolicy;
  static const String helpUrl = kSupportDesk;
  static const String siteUrl = kSiteHome;

  // ─────────────────────────────────────────────────────────
  // Timing
  // ─────────────────────────────────────────────────────────
  /// Interval (seconds) before re-showing the push-invite screen
  /// after a Skip. 3 days per TZ.
  static const int inviteReprompt = 3 * 24 * 60 * 60;

  /// Seconds to wait before re-querying attribution when the SDK
  /// reports Organic on the first callback (false-positive guard).
  static const int organicRecheckDelay = 5;
}
