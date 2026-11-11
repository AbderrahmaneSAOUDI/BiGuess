import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

import '../catalog/catalog_models.dart';
import '../local/local_pack_file.dart';
import '../local/local_pack_store.dart';

enum PackDownloadPhase { downloading, verifying, installing }

class PackDownloadProgress {
  const PackDownloadProgress(this.phase, this.receivedBytes, this.totalBytes);
  final PackDownloadPhase phase;
  final int receivedBytes, totalBytes;
}

class PackDownloadFailure implements Exception {
  const PackDownloadFailure(this.code);
  final String code;
  @override
  String toString() => 'PackDownloadFailure($code)';
}

abstract interface class PackDownloadRepository {
  Future<InstalledLocalPack> download(
    CatalogPackSummary summary, {
    void Function(PackDownloadProgress)? onProgress,
  });
  void close();
}

/// Complete public v1 downloads. Pinned SPKI keys are application configuration,
/// never learned from a response. Only the existing private store can activate.
class HttpPackDownloadRepository implements PackDownloadRepository {
  HttpPackDownloadRepository({
    required Uri base,
    required this.store,
    required Map<String, String> pinnedKeys,
    HttpClient? httpClient,
    this.requestTimeout = const Duration(seconds: 30),
  }) : base = _origin(base),
       pinnedKeys = Map.unmodifiable(pinnedKeys),
       _client = httpClient;
  final Uri base;
  final LocalPackStore store;
  final Map<String, String> pinnedKeys;
  final Duration requestTimeout;
  HttpClient? _client;
  bool _closed = false, _busy = false;
  HttpClient get _http =>
      _client ??= (HttpClient()..connectionTimeout = requestTimeout);

  @override
  Future<InstalledLocalPack> download(
    CatalogPackSummary summary, {
    void Function(PackDownloadProgress)? onProgress,
  }) async {
    if (_closed) throw const PackDownloadFailure('closed');
    if (_busy) throw const PackDownloadFailure('busy');
    if (!summary.available) throw const PackDownloadFailure('unavailable');
    _busy = true;
    Directory? staging;
    try {
      catalogId(summary.id);
      catalogId(summary.topicId);
      final prefix = '/content/v1/packs/${Uri.encodeComponent(summary.id)}';
      final descriptor = _json(
        await _bytes(base.resolve('$prefix/download'), 64 * 1024),
      );
      _record(descriptor, {
        'protocolVersion',
        'packId',
        'revision',
        'manifestUrl',
        'manifestSha256',
        'archiveUrl',
        'archiveSha256',
        'sizeBytes',
        'manifestSchemaVersion',
      });
      if (descriptor['protocolVersion'] != 1 ||
          descriptor['protocolVersion'] is! int ||
          descriptor['manifestSchemaVersion'] != 1 ||
          descriptor['manifestSchemaVersion'] is! int ||
          descriptor['packId'] != summary.id ||
          descriptor['revision'] != summary.revision ||
          descriptor['revision'] is! int ||
          descriptor['manifestSha256'] != summary.manifestSha256) {
        throw const PackDownloadFailure('catalog-changed');
      }
      final revisionBase = base.resolve(
        '$prefix/revisions/${summary.revision}/',
      );
      final manifestUri = revisionBase.resolve('manifest');
      final archiveUri = revisionBase.resolve('archive.biguesspack');
      if (descriptor['manifestUrl'] != manifestUri.toString() ||
          descriptor['archiveUrl'] != archiveUri.toString()) {
        throw const PackDownloadFailure('corrupt');
      }
      final receipt = _json(
        await _bytes(revisionBase.resolve('signature'), 64 * 1024),
      );
      final statement = await _verifyReceipt(receipt, summary);
      if (descriptor['archiveSha256'] != statement['archiveSha256'] ||
          descriptor['sizeBytes'] != statement['archiveSizeBytes']) {
        throw const PackDownloadFailure('corrupt');
      }
      final archiveSize = _size(
        statement['archiveSizeBytes'],
        store.limits.fileBytes,
      );
      final manifestSize = _size(
        statement['manifestSizeBytes'],
        store.limits.fileBytes,
      );
      final manifestBytes = await _bytes(
        manifestUri,
        manifestSize,
        exact: manifestSize,
      );
      _verifyBytes(manifestBytes, statement['manifestSha256']);
      final json = _json(manifestBytes);
      final manifest = LocalPackManifest.fromJson(json);
      if (manifest.pack.id != summary.id ||
          manifest.pack.topicId != summary.topicId ||
          manifest.pack.revision != summary.revision ||
          manifest.cards.length != summary.cardCount ||
          manifest.digest != statement['manifestSha256'] ||
          json['provenance']['mode'] != 'cleared-test') {
        throw const PackDownloadFailure('corrupt');
      }
      // Temp bytes stay under application-private Pack storage and never enter
      // a public gallery. Every exit cleans partial files; no pointer exists yet.
      await store.root.create(recursive: true);
      staging = await store.root.createTemp('download-');
      final archive = File('${staging.path}/archive.biguesspack');
      final output = await archive.open(mode: FileMode.writeOnly);
      final digest = _DigestSink();
      final hash = hashes.sha256.startChunkedConversion(digest);
      var received = 0;
      onProgress?.call(
        PackDownloadProgress(PackDownloadPhase.downloading, 0, archiveSize),
      );
      try {
        await _read(archiveUri, archiveSize, (chunk) async {
          received += chunk.length;
          hash.add(chunk);
          await output.writeFrom(chunk);
          onProgress?.call(
            PackDownloadProgress(
              PackDownloadPhase.downloading,
              received,
              archiveSize,
            ),
          );
        }, exact: archiveSize);
        await output.flush();
      } finally {
        hash.close();
        await output.close();
      }
      if (digest.value?.toString() != statement['archiveSha256']) {
        throw const PackDownloadFailure('corrupt');
      }
      onProgress?.call(
        PackDownloadProgress(
          PackDownloadPhase.verifying,
          received,
          archiveSize,
        ),
      );
      final decoded = LocalPackFile.decode(
        await archive.readAsBytes(),
        store.limits,
      );
      if (decoded.manifest.digest != manifest.digest) {
        throw const PackDownloadFailure('corrupt');
      }
      if (_closed) throw const PackDownloadFailure('closed');
      onProgress?.call(
        PackDownloadProgress(
          PackDownloadPhase.installing,
          received,
          archiveSize,
        ),
      );
      return await store.install(archive);
    } on PackDownloadFailure {
      rethrow;
    } on TimeoutException {
      throw const PackDownloadFailure('timeout');
    } on SocketException {
      throw const PackDownloadFailure('offline');
    } on HttpException {
      throw const PackDownloadFailure('offline');
    } on FileSystemException catch (error) {
      final noSpace =
          {28, 112}.contains(error.osError?.errorCode) ||
          error.message.toLowerCase().contains('no space');
      throw PackDownloadFailure(noSpace ? 'no-space' : 'storage');
    } on StateError {
      throw const PackDownloadFailure('limit');
    } on FormatException {
      throw const PackDownloadFailure('corrupt');
    } finally {
      _busy = false;
      if (staging != null) {
        try {
          await staging.delete(recursive: true);
        } on FileSystemException {
          /* Best effort cleanup. */
        }
      }
    }
  }

  Future<Map<String, dynamic>> _verifyReceipt(
    Map<String, dynamic> receipt,
    CatalogPackSummary summary,
  ) async {
    _record(receipt, {
      'schemaVersion',
      'algorithm',
      'keyId',
      'statement',
      'signature',
    });
    final s = LocalPackManifest.object(receipt['statement']);
    _record(s, {
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
        s['packId'] != summary.id ||
        s['topicId'] != summary.topicId ||
        s['revision'] != summary.revision ||
        s['revision'] is! int ||
        s['manifestSha256'] != summary.manifestSha256 ||
        !_digest(s['archiveSha256']) ||
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

  Future<Uint8List> _bytes(Uri uri, int limit, {int? exact}) async {
    final builder = BytesBuilder(copy: false);
    await _read(uri, limit, (chunk) async {
      builder.add(chunk);
    }, exact: exact);
    return builder.takeBytes();
  }

  Future<void> _read(
    Uri uri,
    int limit,
    Future<void> Function(List<int>) consume, {
    int? exact,
  }) async {
    HttpClientRequest? request;
    try {
      request = await _http.getUrl(uri).timeout(requestTimeout);
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/json, application/zip',
      );
      final response = await request.close().timeout(requestTimeout);
      if ({403, 404, 410}.contains(response.statusCode)) {
        throw const PackDownloadFailure('unavailable');
      }
      if (response.statusCode != 200) {
        throw const PackDownloadFailure('offline');
      }
      if (response.contentLength > limit ||
          (exact != null &&
              response.contentLength >= 0 &&
              response.contentLength != exact)) {
        throw const PackDownloadFailure('corrupt');
      }
      var count = 0;
      await (() async {
        await for (final chunk in response) {
          if (_closed) throw const PackDownloadFailure('closed');
          count += chunk.length;
          if (count > limit) throw const PackDownloadFailure('corrupt');
          await consume(chunk);
        }
      })().timeout(requestTimeout);
      if (exact != null && count != exact) {
        throw const PackDownloadFailure('corrupt');
      }
    } catch (_) {
      request?.abort();
      rethrow;
    }
  }

  @override
  void close() {
    _closed = true;
    _client?.close(force: true);
  }
}

class _DigestSink implements Sink<hashes.Digest> {
  hashes.Digest? value;
  @override
  void add(hashes.Digest data) {
    value = data;
  }

  @override
  void close() {}
}

Uri _origin(Uri value) {
  final local = {'localhost', '127.0.0.1', '::1'}.contains(value.host);
  if (!(value.scheme == 'https' || value.scheme == 'http' && local) ||
      value.host.isEmpty ||
      value.userInfo.isNotEmpty ||
      value.hasQuery ||
      value.hasFragment ||
      !{'', '/'}.contains(value.path)) {
    throw ArgumentError.value(value, 'base', 'Expected a public HTTPS origin');
  }
  return Uri.parse(value.origin);
}

Map<String, dynamic> _json(List<int> bytes) =>
    LocalPackManifest.object(jsonDecode(utf8.decode(bytes)));
void _record(Map<String, dynamic> value, Set<String> keys) =>
    LocalPackManifest.record(value, keys);
bool _digest(Object? value) =>
    value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
int _size(Object? value, int limit) {
  if (value is! int || value < 1 || value > limit) {
    throw const PackDownloadFailure('corrupt');
  }
  return value;
}

void _verifyBytes(List<int> bytes, Object? expected) {
  if (!_digest(expected) ||
      hashes.sha256.convert(bytes).toString() != expected) {
    throw const PackDownloadFailure('corrupt');
  }
}
