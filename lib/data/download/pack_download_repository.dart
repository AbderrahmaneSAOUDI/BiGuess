import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'pack_publication_verifier.dart';

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

/// Per-job cancellation. A cancelled transfer always restarts from byte zero.
class PackDownloadCancellation {
  final _done = Completer<void>();
  final _listeners = <void Function()>{};
  bool get isCancelled => _done.isCompleted;
  void cancel() {
    if (isCancelled) return;
    _done.complete();
    for (final listener in _listeners.toList()) {
      listener();
    }
  }

  void throwIfCancelled() {
    if (isCancelled) throw const PackDownloadFailure('cancelled');
  }

  void Function() listen(void Function() callback) {
    if (isCancelled) {
      callback();
    } else {
      _listeners.add(callback);
    }
    return () => _listeners.remove(callback);
  }

  Future<T> race<T>(Future<T> operation) => Future.any([
    operation,
    _done.future.then<T>((_) => throw const PackDownloadFailure('cancelled')),
  ]);
}

abstract interface class PackDownloadRepository {
  Future<InstalledLocalPack> download(
    CatalogPackSummary summary, {
    void Function(PackDownloadProgress)? onProgress,
    PackDownloadCancellation? cancellation,
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
  PackDownloadCancellation? _activeCancellation;
  HttpClient get _http =>
      _client ??= (HttpClient()..connectionTimeout = requestTimeout);

  @override
  Future<InstalledLocalPack> download(
    CatalogPackSummary summary, {
    void Function(PackDownloadProgress)? onProgress,
    PackDownloadCancellation? cancellation,
  }) async {
    if (_closed) throw const PackDownloadFailure('closed');
    if (_busy) throw const PackDownloadFailure('busy');
    if (!summary.available) throw const PackDownloadFailure('unavailable');
    _busy = true;
    final token = cancellation ?? PackDownloadCancellation();
    _activeCancellation = token;
    PackDownloadStaging? lease;
    Directory? staging;
    try {
      token.throwIfCancelled();
      await store.recoverInterruptedDownloads();
      token.throwIfCancelled();
      catalogId(summary.id);
      catalogId(summary.topicId);
      final prefix = '/content/v1/packs/${Uri.encodeComponent(summary.id)}';
      final descriptor = _json(
        await _bytes(base.resolve('$prefix/download'), 64 * 1024, token: token),
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
        await _bytes(
          revisionBase.resolve('signature'),
          64 * 1024,
          token: token,
        ),
      );
      final statement = await verifyPackPublicationReceipt(
        receipt,
        pinnedKeys: pinnedKeys,
        packId: summary.id,
        topicId: summary.topicId,
        revision: summary.revision,
        manifestSha256: summary.manifestSha256,
      );
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
        token: token,
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
      token.throwIfCancelled();
      lease = await store.createDownloadStaging();
      staging = lease.directory;
      token.throwIfCancelled();
      final archive = File('${staging.path}/archive.biguesspack');
      final output = await archive.open(mode: FileMode.writeOnly);
      final digest = _DigestSink();
      final hash = hashes.sha256.startChunkedConversion(digest);
      var received = 0;
      onProgress?.call(
        PackDownloadProgress(PackDownloadPhase.downloading, 0, archiveSize),
      );
      try {
        await _read(
          archiveUri,
          archiveSize,
          (chunk) async {
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
          },
          exact: archiveSize,
          token: token,
        );
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
      token.throwIfCancelled();
      onProgress?.call(
        PackDownloadProgress(
          PackDownloadPhase.installing,
          received,
          archiveSize,
        ),
      );
      return await store.install(
        archive,
        checkCancelled: token.throwIfCancelled,
      );
    } on PackDownloadFailure {
      rethrow;
    } on TimeoutException {
      throw const PackDownloadFailure('timeout');
    } on SocketException {
      token.throwIfCancelled();
      throw const PackDownloadFailure('offline');
    } on HttpException {
      token.throwIfCancelled();
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
      try {
        if (lease != null) await lease.release();
      } finally {
        _activeCancellation = null;
        _busy = false;
      }
    }
  }

  Future<Uint8List> _bytes(
    Uri uri,
    int limit, {
    int? exact,
    required PackDownloadCancellation token,
  }) async {
    final builder = BytesBuilder(copy: false);
    await _read(
      uri,
      limit,
      (chunk) async {
        builder.add(chunk);
      },
      exact: exact,
      token: token,
    );
    return builder.takeBytes();
  }

  Future<void> _read(
    Uri uri,
    int limit,
    Future<void> Function(List<int>) consume, {
    int? exact,
    required PackDownloadCancellation token,
  }) async {
    HttpClientRequest? request;
    final detach = token.listen(
      () => request?.abort(const PackDownloadFailure('cancelled')),
    );
    try {
      token.throwIfCancelled();
      final openedRequest = await token.race(
        _http
            .getUrl(uri)
            .then((opened) {
              if (token.isCancelled) {
                opened.abort(const PackDownloadFailure('cancelled'));
              }
              return opened;
            })
            .timeout(requestTimeout),
      );
      request = openedRequest;
      token.throwIfCancelled();
      openedRequest.followRedirects = false;
      openedRequest.headers.set(
        HttpHeaders.acceptHeader,
        'application/json, application/zip',
      );
      final response = await token.race(
        openedRequest.close().timeout(requestTimeout),
      );
      token.throwIfCancelled();
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
          token.throwIfCancelled();
          count += chunk.length;
          if (count > limit) throw const PackDownloadFailure('corrupt');
          await consume(chunk);
          token.throwIfCancelled();
        }
      })().timeout(requestTimeout);
      token.throwIfCancelled();
      if (exact != null && count != exact) {
        throw const PackDownloadFailure('corrupt');
      }
    } catch (_) {
      request?.abort();
      token.throwIfCancelled();
      rethrow;
    } finally {
      detach();
    }
  }

  @override
  void close() {
    _closed = true;
    _activeCancellation?.cancel();
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
