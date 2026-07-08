// ignore_for_file: avoid_print
//
// PEAK secret packer.
// Encodes plaintext endpoints/keys into byte arrays that mirror the
// scheme in `lib/cipher/peak_cipher.dart`. Run with:
//   dart run tool/pack_secrets.dart
// then paste the arrays into `lib/config/locked_parcels.dart`.
//
// Both `saltPhrase` + `ringSize` MUST match the values in
// peak_cipher.dart exactly.

const String saltPhrase = 'V7#kQ2mZ_th_9pX';
const int ringSize = 33;

List<int> _brewRing() {
  int h = 0x811C9DC5;
  for (final int c in saltPhrase.codeUnits) {
    h = (h ^ c) & 0xFFFFFFFF;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  int s = h == 0 ? 0xB5297A4D : h;
  final List<int> ring = List<int>.filled(ringSize, 0);
  for (int i = 0; i < ringSize; i++) {
    s ^= (s << 13) & 0xFFFFFFFF;
    s ^= s >> 17;
    s ^= (s << 5) & 0xFFFFFFFF;
    s &= 0xFFFFFFFF;
    ring[i] = (s >> 16) & 0xFF;
  }
  return ring;
}

final List<int> ring = _brewRing();

List<int> pack(String plain) {
  final List<int> bytes = plain.codeUnits;
  final List<int> out = List<int>.filled(bytes.length, 0);
  for (int i = 0; i < bytes.length; i++) {
    out[i] = (bytes[i] ^ ring[i % ringSize] ^ ((i * 3 + 7) & 0xFF)) & 0xFF;
  }
  return out;
}

void emit(String label, String plain) {
  if (plain.isEmpty) {
    print('// $label — (empty; leave <int>[] until manager provides)');
    print('const <int>[];\n');
    return;
  }
  final List<int> packed = pack(plain);
  final String body = packed.join(', ');
  print('// $label  <= "$plain"');
  print('const <int>[$body],\n');
}

void main() {
  const String gateEndpoint = 'https://thunderrpeak.com/config.php';
  const String gcdBase = 'https://gcdsdk.appsflyer.com/install_data/v4.0/';
  const String chromeVersion = '149.0.7827.163';
  const String webkitVersion = '537.36';

  // Provisioned by the manager.
  const String attrKey = 'JZ6JLeVQjxw5aQheAR2RFJ'; // AppsFlyer Dev Key
  const String messagingProject = '718133543018'; // Firebase project number

  print('=== ThunderPeak secret parcels ===\n');
  emit('_parcelGateEndpoint', gateEndpoint);
  emit('_parcelGcdBase', gcdBase);
  emit('_parcelChromeVersion', chromeVersion);
  emit('_parcelWebkitVersion', webkitVersion);
  emit('_parcelAttrKey', attrKey);
  emit('_parcelMessagingProject', messagingProject);
}
