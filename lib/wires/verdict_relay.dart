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

import 'package:flutter/foundation.dart';

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
      debugPrint('[GRAY][GATE] endpoint is empty — nothing to ask');
      return GateVerdict.rejected('endpoint-missing');
    }

    final Stopwatch stopwatch = Stopwatch()..start();
    debugPrint('[GRAY][GATE] POST $endpoint');
    debugPrint('[GRAY][GATE] req.body = ${jsonEncode(body)}');
    debugPrint('[GRAY][GATE] req.user_agent = ${peakHttp.agent}');

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

      stopwatch.stop();
      debugPrint('[GRAY][GATE] http=${res.statusCode} '
          'took=${stopwatch.elapsedMilliseconds}ms '
          'bytes=${res.body.length}');
      debugPrint('[GRAY][GATE] res.body = ${res.body}');

      if (res.statusCode != 200) {
        return GateVerdict.rejected('http-${res.statusCode}');
      }

      final dynamic parsedDyn = jsonDecode(res.body);
      if (parsedDyn is! Map<String, dynamic>) {
        debugPrint('[GRAY][GATE] response is not a JSON object: '
            '${parsedDyn.runtimeType}');
        return GateVerdict.rejected('bad-shape');
      }
      final GateVerdict verdict = GateVerdict.fromMap(parsedDyn);
      debugPrint('[GRAY][GATE] verdict.approved=${verdict.approved} '
          'url=${verdict.contentUrl} '
          'expires=${verdict.expiresAt} '
          'remark=${verdict.remark}');

      if (verdict.approved && verdict.hasContent) {
        await _safe.writeLink(verdict.contentUrl!);
        if (verdict.expiresAt != null) {
          await _safe.writeLinkExpiry(verdict.expiresAt!);
        }
      }
      return verdict;
    } catch (e, st) {
      stopwatch.stop();
      debugPrint('[GRAY][GATE] threw after '
          '${stopwatch.elapsedMilliseconds}ms: $e');
      debugPrint('[GRAY][GATE] stack: $st');
      return GateVerdict.rejected(e.toString());
    }
  }

  Future<String?> cachedContent() => _safe.readLink();
}
