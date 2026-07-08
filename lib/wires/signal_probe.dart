// ============================================================
// SIGNAL PROBE — connectivity helper
// ============================================================
// Wraps `connectivity_plus` with a real DNS lookup. Adapter state
// alone is unreliable — VPNs, captive portals, and airplane-mode
// transitions can flip it while the network is actually usable
// (or vice versa). The DNS probe closes those gaps.
//
// PITFALLS ADDRESSED (see .cursor/rules/gray_part_pitfalls.md §3):
//   • VPN is treated as connectivity, not "none".
//   • DNS timeout is 7 s (not 3 s) so slow tunnels are not falsely
//     marked offline.
// ============================================================

import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';

const Set<ConnectivityResult> _liveInterfaces = <ConnectivityResult>{
  ConnectivityResult.wifi,
  ConnectivityResult.mobile,
  ConnectivityResult.ethernet,
  ConnectivityResult.vpn,
  ConnectivityResult.bluetooth,
  ConnectivityResult.other,
};

class SignalProbe {
  SignalProbe({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  /// True when we can resolve DNS AND at least one live interface is up.
  Future<bool> hasNetwork() async {
    final List<ConnectivityResult> states =
        await _connectivity.checkConnectivity();
    if (!states.any(_liveInterfaces.contains)) return false;

    try {
      final List<InternetAddress> probe = await InternetAddress.lookup(
        'one.one.one.one',
      ).timeout(const Duration(seconds: 7));
      return probe.isNotEmpty && probe.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Stream<List<ConnectivityResult>> get onChange =>
      _connectivity.onConnectivityChanged;
}
