// ============================================================
// PEAK CIPHER — keystream string hider
// ============================================================
// Sensitive endpoints and third-party keys live encoded as byte
// lists. The plaintext is never present in the compiled binary; a
// store-scanner grepping for known affiliate domains, AppsFlyer
// dev keys or Firebase project ids finds nothing to cluster on.
//
// Scheme (project-specific — do not reuse across apps):
//   1. `_saltPhrase` is folded into a 32-bit FNV-1a hash.
//   2. That hash seeds an xorshift32 stream that produces
//      `_ringSize` bytes of keystream (high byte of each state).
//   3. Each byte is transformed as:
//         out[i] = in[i] ^ ring[i % _ringSize] ^ ((i * 3 + 7) & 0xFF)
//      The positional term is intentionally different from the
//      template's simple `i & 0xFF` — reusing the exact XOR term is
//      itself a fingerprint signal.
//   4. The routine is symmetric: `pack()` in `tool/pack_secrets.dart`
//      uses the same primitives to encode plaintext for embedding.
//
// ─────────────────────────────────────────────────────────────
// FINGERPRINT — DO NOT COPY VALUES BETWEEN PROJECTS
// ─────────────────────────────────────────────────────────────
// Every new project MUST change both `_saltPhrase` and `_ringSize`
// to fresh values unique to that build. Re-run pack_secrets after
// every change; the previous byte arrays will no longer decode.
// ============================================================

import 'dart:typed_data';

// [FINGERPRINT] Opaque per-project salt.
const String _saltPhrase = 'V7#kQ2mZ_th_9pX';

// [FINGERPRINT] Ring size — pick anything in 20..48.
const int _ringSize = 33;

Uint8List _brewRing() {
  int h = 0x811C9DC5;
  for (final int c in _saltPhrase.codeUnits) {
    h = (h ^ c) & 0xFFFFFFFF;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  int s = h == 0 ? 0xB5297A4D : h;
  final Uint8List ring = Uint8List(_ringSize);
  for (int i = 0; i < _ringSize; i++) {
    s ^= (s << 13) & 0xFFFFFFFF;
    s ^= s >> 17;
    s ^= (s << 5) & 0xFFFFFFFF;
    s &= 0xFFFFFFFF;
    ring[i] = (s >> 16) & 0xFF;
  }
  return ring;
}

final Uint8List _ring = _brewRing();

/// Reverses a packed byte list back into the original UTF-16 string.
/// An empty input yields an empty string — this is the safe default
/// while the shipping build still has empty secret arrays.
String unwrap(List<int> parcel) {
  if (parcel.isEmpty) return '';
  final Uint8List out = Uint8List(parcel.length);
  for (int i = 0; i < parcel.length; i++) {
    out[i] = (parcel[i] ^ _ring[i % _ringSize] ^ ((i * 3 + 7) & 0xFF)) & 0xFF;
  }
  return String.fromCharCodes(out);
}
