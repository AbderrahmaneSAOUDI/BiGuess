import 'dart:convert';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

import '../local/local_pack_file.dart';
import 'pack_download_repository.dart' show PackDownloadFailure;

/// Shared trust boundary for full and incremental public Pack installation.
/// Keys come only from reviewed build configuration, never a server response.
Future<Map<String, dynamic>> verifyPackPublicationReceipt(
  Map<String, dynamic> receipt, {
  required Map<String, String> pinnedKeys,
  required String packId,
  required String topicId,
  required int revision,
  required String manifestSha256,
}) async {
  LocalPackManifest.record(receipt, {
    'schemaVersion',
    'algorithm',
    'keyId',
    'statement',
    'signature',
  });
  final s = LocalPackManifest.object(receipt['statement']);
  LocalPackManifest.record(s, {
    'archiveSha256',
    'archiveSizeBytes',
    'domain',
    'manifestSha256',
    'manifestSizeBytes',
    'packId',
    'revision',
    'topicId',
  });
  if (receipt['schemaVersion'] != 1 ||
      receipt['schemaVersion'] is! int ||
      receipt['algorithm'] != 'Ed25519' ||
      receipt['signature'] is! String ||
      s['domain'] != 'biguess-pack-publication-v1' ||
      s['packId'] != packId ||
      s['topicId'] != topicId ||
      s['revision'] != revision ||
      s['revision'] is! int ||
      s['manifestSha256'] != manifestSha256 ||
      !_digest(s['archiveSha256']) ||
      !_digest(s['manifestSha256']) ||
      !_size(s['archiveSizeBytes']) ||
      !_size(s['manifestSizeBytes']) ||
      !_digest(receipt['keyId'])) {
    throw const PackDownloadFailure('corrupt');
  }
  final encoded = pinnedKeys[receipt['keyId']];
  if (encoded == null) throw const PackDownloadFailure('untrusted-key');
  final spki = base64.decode(encoded);
  const prefix = [
    0x30,
    0x2a,
    0x30,
    0x05,
    0x06,
    0x03,
    0x2b,
    0x65,
    0x70,
    0x03,
    0x21,
    0x00,
  ];
  if (spki.length != 44 ||
      hashes.sha256.convert(spki).toString() != receipt['keyId'] ||
      !List.generate(
        prefix.length,
        (i) => spki[i] == prefix[i],
      ).every((v) => v)) {
    throw const PackDownloadFailure('untrusted-key');
  }
  final signature = base64.decode(receipt['signature'] as String);
  if (signature.length != 64) throw const PackDownloadFailure('corrupt');
  // The publisher signs this exact fixed field order followed by one newline.
  final bytes = utf8.encode(
    '${jsonEncode({'archiveSha256': s['archiveSha256'], 'archiveSizeBytes': s['archiveSizeBytes'], 'domain': s['domain'], 'manifestSha256': s['manifestSha256'], 'manifestSizeBytes': s['manifestSizeBytes'], 'packId': s['packId'], 'revision': s['revision'], 'topicId': s['topicId']})}\n',
  );
  final valid = await Ed25519().verify(
    bytes,
    signature: Signature(
      signature,
      publicKey: SimplePublicKey(spki.sublist(12), type: KeyPairType.ed25519),
    ),
  );
  if (!valid) throw const PackDownloadFailure('corrupt');
  return s;
}

bool _digest(Object? value) =>
    value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
bool _size(Object? value) =>
    value is int && value > 0 && value <= 9007199254740991;
