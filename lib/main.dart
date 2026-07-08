// ============================================================
// ThunderPeak — bootstrap
// ============================================================
// Wiring order (must NOT change without reading the guide):
//   1. WidgetsFlutterBinding — required before any plugin call.
//   2. Firebase + AppCheck   — wrapped in try/catch. The app must
//      boot even without google-services.json (falls back to the
//      native game if the gate cannot be reached).
//   3. Orientation whitelist — all four are enabled so the loading
//      + WebView screens rotate freely. The native ArenaScreen /
//      SummitMenu re-locks to portrait once we route into it.
//   4. peakHttp.prepare()    — forges the device UA used by BOTH
//      the HTTP client and the WebView. Prepared FIRST so that the
//      first VerdictRelay call already has the real UA.
//   5. PeakSafe.preheat()    — reads SharedPreferences so the very
//      first frame of AscentRouter can decide the route without an
//      async await (no blank splash).
//   6. Wires are constructed but not `arm()`-ed here; BoltBeacon /
//      TraceOracle boot inside AscentRouter once the UI is up.
// ============================================================

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'harness/root_shell.dart';
import 'wires/bolt_beacon.dart';
import 'wires/peak_safe.dart';
import 'wires/signal_probe.dart';
import 'wires/trace_oracle.dart';
import 'wires/ua_forge.dart';
import 'wires/verdict_relay.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase + App Check are optional until credentials are
  // provisioned. Failures must not block startup — the app just
  // falls back to the native game path.
  try {
    await Firebase.initializeApp();
    await FirebaseAppCheck.instance.activate(
      providerAndroid: kDebugMode
          ? const AndroidDebugProvider()
          : const AndroidPlayIntegrityProvider(),
    );
  } catch (_) {}

  await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));

  // Build the UA before any bridge that talks to the network.
  await peakHttp.prepare();

  final PeakSafe safe = PeakSafe();
  await safe.preheat();

  final SignalProbe probe = SignalProbe();
  final TraceOracle oracle = TraceOracle();
  final VerdictRelay relay = VerdictRelay(safe);
  final BoltBeacon beacon = BoltBeacon(safe);

  runApp(RootShell(
    safe: safe,
    probe: probe,
    oracle: oracle,
    relay: relay,
    beacon: beacon,
  ));
}
