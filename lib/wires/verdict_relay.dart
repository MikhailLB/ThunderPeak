// ============================================================
// VERDICT RELAY — posts the gate body, parses the reply
// ============================================================
// Single HTTP round-trip to the gate endpoint. On a successful
// approval the returned URL + expiry are persisted so that a
// returning launch can fall back to the same content if the
// network is briefly unavailable.
//
// Failure semantics (see gray-flow guide § "Behavior contract on
// failure") are enforced by the caller — this relay only reports
// what happened; it does NOT decide whether to persist offline
// mode.
// ============================================================

import 'dart:convert';

import '../config/peak_blueprint.dart';
import '../kernel/gate_verdict.dart';
import 'peak_safe.dart';
import 'ua_forge.dart';

class VerdictRelay {
  VerdictRelay(this._safe);

  final PeakSafe _safe;

  Future<GateVerdict> ask(Map<String, dynamic> body) async {
    final String endpoint = PeakBlueprint.gateEndpoint;
    if (endpoint.isEmpty) {
      return GateVerdict.rejected('endpoint-missing');
    }

    try {
      final dynamic res = await peakHttp
          .post(
            Uri.parse(endpoint),
            headers: const <String, String>{
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode != 200) {
        return GateVerdict.rejected('http-${res.statusCode}');
      }

      final Map<String, dynamic> parsed =
          jsonDecode(res.body) as Map<String, dynamic>;
      final GateVerdict verdict = GateVerdict.fromMap(parsed);

      if (verdict.approved && verdict.hasContent) {
        await _safe.writeLink(verdict.contentUrl!);
        if (verdict.expiresAt != null) {
          await _safe.writeLinkExpiry(verdict.expiresAt!);
        }
      }
      return verdict;
    } catch (e) {
      return GateVerdict.rejected(e.toString());
    }
  }

  Future<String?> cachedContent() => _safe.readLink();
}
