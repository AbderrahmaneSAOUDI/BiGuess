import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as hashes;

import '../download/pack_download_repository.dart';
import '../download/pack_publication_verifier.dart';
import '../local/local_pack_file.dart';
import '../local/local_pack_store.dart';
import '../local/pack_tombstone.dart';
import '../local/private_pack_images.dart';

enum PackUpdateAvailability {
  upToDate,
  updateAvailable,
  unavailable,
  deleted,
  unknown,
}

class PackUpdateStatus {
  const PackUpdateStatus({
    required this.packId,
    required this.installedRevision,
    required this.state,
    this.revision,
    this.manifestSha256,
    this.tombstone,
  });
  final String packId;
  final int installedRevision;
  final PackUpdateAvailability state;
  final int? revision;
  final String? manifestSha256;
  final PackTombstone? tombstone;
}

class _KnownPackRevision {
  const _KnownPackRevision(this.packId, this.revision, this.digest);
  final String packId, digest;
  final int revision;
}

abstract interface class PackUpdateRepository {
  Future<List<PackUpdateStatus>> check({
    PackDownloadCancellation? cancellation,
  });
  Future<InstalledLocalPack> update(
    PackUpdateStatus status, {
    void Function(PackDownloadProgress)? onProgress,
    PackDownloadCancellation? cancellation,
  });
  void close();
}

/// Manual public distribution only. Construction and local reads are inert;
/// no catalog cache or running GameSession is modified by this repository.
class HttpPackUpdateRepository implements PackUpdateRepository {
  HttpPackUpdateRepository({
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
  HttpClient get _http =>
      _client ??= (HttpClient()..connectionTimeout = requestTimeout);
  bool _closed = false, _busy = false;
  PackDownloadCancellation? _active;

  Future<T> _run<T>(
    PackDownloadCancellation? cancellation,
    Future<T> Function(PackDownloadCancellation) action,
  ) async {
    if (_closed) throw const PackDownloadFailure('closed');
    if (_busy) throw const PackDownloadFailure('busy');
    _busy = true;
    final token = cancellation ?? PackDownloadCancellation();
    _active = token;
    try {
      token.throwIfCancelled();
      return await action(token);
    } on PackDownloadFailure {
      rethrow;
    } on TimeoutException {
      token.throwIfCancelled();
      throw const PackDownloadFailure('timeout');
    } on SocketException {
      token.throwIfCancelled();
      throw const PackDownloadFailure('offline');
    } on HttpException {
      token.throwIfCancelled();
      throw const PackDownloadFailure('offline');
    } on FileSystemException catch (error) {
      throw PackDownloadFailure(
        {28, 112}.contains(error.osError?.errorCode) ||
                error.message.toLowerCase().contains('no space')
            ? 'no-space'
            : 'storage',
      );
    } on FormatException {
      throw const PackDownloadFailure('corrupt');
    } on ArgumentError {
      throw const PackDownloadFailure('corrupt');
    } on PackDeletedException {
      throw const PackDownloadFailure('deleted');
    } on StateError {
      throw const PackDownloadFailure('limit');
    } finally {
      _active = null;
      _busy = false;
    }
  }

  @override
  Future<List<PackUpdateStatus>> check({
    PackDownloadCancellation? cancellation,
  }) => _run(cancellation, (token) async {
    // Local development imports are not public distribution identities. Never
    // disclose their IDs to the anonymous revision endpoint. User-removed
    // public Packs remain known so a later manual sync can learn a tombstone.
    final known = <String, _KnownPackRevision>{
      for (final pack in await store.readAllInstalled())
        if (pack.manifest.toJson()['provenance']['mode'] == 'cleared-test')
          pack.manifest.pack.id: _KnownPackRevision(
            pack.manifest.pack.id,
            pack.manifest.pack.revision,
            pack.manifest.digest,
          ),
    };
    for (final removed in await store.readRetirements()) {
      if (removed.publicSyncEligible && removed.tombstone == null) {
        known.putIfAbsent(
          removed.packId,
          () => _KnownPackRevision(
            removed.packId,
            removed.installedRevision,
            removed.manifestSha256,
          ),
        );
      }
    }
    final installed = known.values.toList()
      ..sort((a, b) => a.packId.compareTo(b.packId));
    token.throwIfCancelled();
    if (installed.length > 10000) throw const PackDownloadFailure('limit');
    final statuses = <PackUpdateStatus>[];
    for (var start = 0; start < installed.length; start += 100) {
      token.throwIfCancelled();
      final batch = installed.skip(start).take(100).toList();
      final reply = await _request(
        base.resolve('/content/v1/sync/revisions'),
        token,
        limit: 512 * 1024,
        body: {
          'protocolVersion': 1,
          'packs': [
            for (final pack in batch)
              {'packId': pack.packId, 'revision': pack.revision},
          ],
        },
      );
      final envelope = _object(reply.bytes);
      _record(envelope, {'protocolVersion', 'results'});
      if (envelope['protocolVersion'] is! int ||
          envelope['protocolVersion'] != 1 ||
          envelope['results'] is! List ||
          (envelope['results'] as List).length != batch.length) {
        throw const PackDownloadFailure('corrupt');
      }
      for (var i = 0; i < batch.length; i++) {
        final old = batch[i];
        final row = LocalPackManifest.object(envelope['results'][i]);
        if (row['packId'] != old.packId) {
          throw const PackDownloadFailure('corrupt');
        }
        final state = row['status'];
        if (state == 'unchanged' || state == 'updateAvailable') {
          _record(row, {'packId', 'status', 'revision', 'manifestSha256'});
          final revision = row['revision'];
          if (revision is! int ||
              !_digest(row['manifestSha256']) ||
              (state == 'unchanged'
                  ? revision != old.revision ||
                        row['manifestSha256'] != old.digest
                  : revision <= old.revision)) {
            throw const PackDownloadFailure('corrupt');
          }
          statuses.add(
            PackUpdateStatus(
              packId: old.packId,
              installedRevision: old.revision,
              state: state == 'unchanged'
                  ? PackUpdateAvailability.upToDate
                  : PackUpdateAvailability.updateAvailable,
              revision: revision,
              manifestSha256: row['manifestSha256'] as String,
            ),
          );
        } else if (state == 'deleted') {
          _record(row, {'packId', 'status', 'tombstone'});
          final tombstone = PackTombstone.fromWire(
            LocalPackManifest.object(row['tombstone']),
            sourceOrigin: base.origin,
          );
          if (tombstone.packId != old.packId ||
              tombstone.revision <= old.revision) {
            throw const PackDownloadFailure('corrupt');
          }
          statuses.add(
            PackUpdateStatus(
              packId: old.packId,
              installedRevision: old.revision,
              state: PackUpdateAvailability.deleted,
              revision: tombstone.revision,
              tombstone: tombstone,
            ),
          );
        } else if (state == 'unavailable' || state == 'unknown') {
          _record(row, {'packId', 'status'});
          statuses.add(
            PackUpdateStatus(
              packId: old.packId,
              installedRevision: old.revision,
              state: state == 'unavailable'
                  ? PackUpdateAvailability.unavailable
                  : PackUpdateAvailability.unknown,
            ),
          );
        } else {
          throw const PackDownloadFailure('corrupt');
        }
      }
    }
    return List.unmodifiable(statuses);
  });

  @override
  Future<InstalledLocalPack> update(
    PackUpdateStatus status, {
    void Function(PackDownloadProgress)? onProgress,
    PackDownloadCancellation? cancellation,
  }) => _run(cancellation, (token) async {
    if (status.state != PackUpdateAvailability.updateAvailable ||
        status.revision == null ||
        status.revision! <= status.installedRevision ||
        !_digest(status.manifestSha256)) {
      throw const PackDownloadFailure('catalog-changed');
    }
    await store.recoverInterruptedDownloads();
    token.throwIfCancelled();
    final installed = await store.readInstalled(status.packId);
    if (installed == null ||
        installed.manifest.pack.revision != status.installedRevision) {
      throw const PackDownloadFailure('catalog-changed');
    }
    final old = installed.manifest.toJson();
    if (old['provenance']['mode'] != 'cleared-test') {
      throw const PackDownloadFailure('unavailable');
    }
    final prefix = '/content/v1/packs/${Uri.encodeComponent(status.packId)}';
    final revisionBase = base.resolve('$prefix/revisions/${status.revision}/');
    final deltaReply = await _request(
      base
          .resolve('$prefix/delta')
          .replace(
            queryParameters: {
              'fromRevision': '${status.installedRevision}',
              'toRevision': '${status.revision}',
              'includeManifestPatch': '1',
            },
          ),
      token,
      limit: 4 * 1024 * 1024,
    );
    final delta = _object(deltaReply.bytes);
    _record(delta, {
      'protocolVersion',
      'packId',
      'fromRevision',
      'toRevision',
      'targetManifestSha256',
      'targetManifestUrl',
      'upsertCards',
      'removeCardIds',
      'objects',
      'manifestPatch',
    });
    if (delta['protocolVersion'] is! int ||
        delta['protocolVersion'] != 1 ||
        delta['packId'] != status.packId ||
        delta['fromRevision'] is! int ||
        delta['fromRevision'] != status.installedRevision ||
        delta['toRevision'] is! int ||
        delta['toRevision'] != status.revision ||
        delta['targetManifestSha256'] != status.manifestSha256 ||
        delta['targetManifestUrl'] !=
            revisionBase.resolve('manifest').toString()) {
      throw const PackDownloadFailure('corrupt');
    }
    final tag = deltaReply.etag;
    if (tag != null && tag != '"${hashes.sha256.convert(deltaReply.bytes)}"') {
      throw const PackDownloadFailure('corrupt');
    }
    final reconstructed = _reconstruct(old, delta);
    final manifest = LocalPackManifest.fromJson(reconstructed);
    final receipt = _object(
      (await _request(
        revisionBase.resolve('signature'),
        token,
        limit: 64 * 1024,
      )).bytes,
    );
    final statement = await verifyPackPublicationReceipt(
      receipt,
      pinnedKeys: pinnedKeys,
      packId: status.packId,
      topicId: installed.manifest.topic.id,
      revision: status.revision!,
      manifestSha256: status.manifestSha256!,
    );
    if (manifest.pack.id != status.packId ||
        manifest.pack.topicId != installed.manifest.topic.id ||
        manifest.pack.revision != status.revision ||
        manifest.digest != status.manifestSha256 ||
        manifest.metadataBytes.length != statement['manifestSizeBytes'] ||
        reconstructed['provenance']['mode'] != 'cleared-test') {
      throw const PackDownloadFailure('corrupt');
    }
    final targetBytes =
        manifest.metadataBytes.length +
        manifest.images.fold<int>(0, (sum, image) => sum + image.size);
    if (targetBytes > store.limits.fileBytes ||
        manifest.images.any(
          (image) => image.size > PrivatePackImages.maxImageBytes,
        )) {
      throw const PackDownloadFailure('corrupt');
    }
    final oldImages = {
      for (final image in installed.manifest.images) image.path: image,
    };
    final remoteObjects = {
      for (final raw in delta['objects'] as List)
        (raw as Map<String, dynamic>)['key'] as String: LocalPackImage.fromJson(
          raw,
        ),
    };
    final objects = <String, Uint8List>{};
    final references = {
      for (final card in installed.cards)
        PrivateImageReference.parse(card.imageReference).objectPath:
            card.imageReference,
    };
    var received = 0;
    final total = remoteObjects.values.fold<int>(
      0,
      (sum, image) => sum + image.size,
    );
    if (total > store.limits.fileBytes) {
      throw const PackDownloadFailure('corrupt');
    }
    PackDownloadStaging? lease;
    try {
      lease = await store.createDownloadStaging();
      for (final image in manifest.images) {
        token.throwIfCancelled();
        if (oldImages.containsKey(image.path)) {
          if (remoteObjects.containsKey(image.path)) {
            throw const PackDownloadFailure('corrupt');
          }
          objects[image.path] = await PrivatePackImages.read(
            store.root,
            PrivateImageReference.parse(references[image.path]!),
          );
          image.verify(objects[image.path]!);
        } else {
          final descriptor = remoteObjects.remove(image.path);
          if (descriptor == null ||
              descriptor.size != image.size ||
              descriptor.hash != image.hash ||
              descriptor.mediaType != image.mediaType) {
            throw const PackDownloadFailure('corrupt');
          }
          final bytes = (await _request(
            revisionBase.resolve(image.path),
            token,
            limit: image.size,
            exact: image.size,
          )).bytes;
          image.verify(bytes);
          objects[image.path] = bytes;
          received += bytes.length;
          onProgress?.call(
            PackDownloadProgress(
              PackDownloadPhase.downloading,
              received,
              total,
            ),
          );
        }
      }
      if (remoteObjects.isNotEmpty) throw const PackDownloadFailure('corrupt');
      token.throwIfCancelled();
      onProgress?.call(
        PackDownloadProgress(PackDownloadPhase.verifying, received, total),
      );
      final archive = Archive();
      for (final entry in {
        'manifest.json': Uint8List.fromList(manifest.metadataBytes),
        ...objects,
      }.entries) {
        archive.add(
          ArchiveFile(entry.key, entry.value.length, entry.value)
            ..compression = CompressionType.none
            ..mode = 0x81a4,
        );
      }
      final archiveBytes = ZipEncoder().encodeBytes(archive);
      if (archiveBytes.length > store.limits.fileBytes) {
        throw const PackDownloadFailure('corrupt');
      }
      final staged = File('${lease.directory.path}/delta.biguesspack');
      await staged.writeAsBytes(archiveBytes, flush: true);
      token.throwIfCancelled();
      onProgress?.call(
        PackDownloadProgress(PackDownloadPhase.installing, received, total),
      );
      return await store.install(
        staged,
        checkCancelled: token.throwIfCancelled,
      );
    } finally {
      await lease?.release();
    }
  });

  Map<String, dynamic> _reconstruct(
    Map<String, dynamic> old,
    Map<String, dynamic> delta,
  ) {
    final patch = LocalPackManifest.record(delta['manifestPatch'], {
      'topic',
      'pack',
      'provenanceMode',
      'packRights',
      'upsertCardRights',
      'cardOrder',
      'objectOrder',
    });
    final cards = _rows(old['cards'], 'id');
    final upserts = _rows(delta['upsertCards'], 'id');
    final removed = _strings(delta['removeCardIds']);
    if (removed.any(
      (id) => !cards.containsKey(id) || upserts.containsKey(id),
    )) {
      throw const PackDownloadFailure('corrupt');
    }
    for (final id in removed) {
      cards.remove(id);
    }
    cards.addAll(upserts);
    final order = _strings(patch['cardOrder']);
    if (order.length != cards.length ||
        !cards.keys.toSet().containsAll(order)) {
      throw const PackDownloadFailure('corrupt');
    }
    final images = _rows(old['objects'], 'key');
    final added = _rows(delta['objects'], 'key');
    if (added.keys.any(images.containsKey)) {
      throw const PackDownloadFailure('corrupt');
    }
    images.addAll(added);
    final imageOrder = _strings(patch['objectOrder']);
    if (imageOrder.any((key) => !images.containsKey(key)) ||
        added.keys.any((key) => !imageOrder.contains(key))) {
      throw const PackDownloadFailure('corrupt');
    }
    final rights = _rows(old['provenance']['cardRights'], 'id');
    final changedRights = _rows(patch['upsertCardRights'], 'id');
    if (changedRights.keys.any((id) => !order.contains(id))) {
      throw const PackDownloadFailure('corrupt');
    }
    rights.addAll(changedRights);
    if (order.any((id) => !rights.containsKey(id))) {
      throw const PackDownloadFailure('corrupt');
    }
    return {
      'schemaVersion': 1,
      'kind': 'full',
      'topic': patch['topic'],
      'pack': patch['pack'],
      'cards': [for (final id in order) cards[id]],
      'objects': [for (final key in imageOrder) images[key]],
      'provenance': {
        'mode': patch['provenanceMode'],
        'packRights': patch['packRights'],
        'cardRights': [for (final id in order) rights[id]],
      },
    };
  }

  Future<_Reply> _request(
    Uri uri,
    PackDownloadCancellation token, {
    required int limit,
    int? exact,
    Map<String, dynamic>? body,
  }) async {
    token.throwIfCancelled();
    HttpClientRequest? request;
    final detach = token.listen(
      () => request?.abort(const PackDownloadFailure('cancelled')),
    );
    try {
      final openedRequest = await token.race(
        (body == null ? _http.getUrl(uri) : _http.postUrl(uri))
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
        'application/json, image/png, image/jpeg, image/webp',
      );
      if (body != null) {
        openedRequest.headers.contentType = ContentType.json;
        openedRequest.add(utf8.encode(jsonEncode(body)));
      }
      final response = await token.race(
        openedRequest.close().timeout(requestTimeout),
      );
      if ({403, 404, 410}.contains(response.statusCode)) {
        throw const PackDownloadFailure('unavailable');
      }
      if (response.statusCode == 409) {
        throw const PackDownloadFailure('delta-unavailable');
      }
      if (response.statusCode != 200) {
        throw const PackDownloadFailure('offline');
      }
      if (response.contentLength > limit ||
          exact != null &&
              response.contentLength >= 0 &&
              response.contentLength != exact) {
        throw const PackDownloadFailure('corrupt');
      }
      final builder = BytesBuilder(copy: false);
      await (() async {
        await for (final chunk in response) {
          token.throwIfCancelled();
          if (builder.length + chunk.length > limit) {
            throw const PackDownloadFailure('corrupt');
          }
          builder.add(chunk);
        }
      })().timeout(requestTimeout);
      token.throwIfCancelled();
      if (exact != null && builder.length != exact) {
        throw const PackDownloadFailure('corrupt');
      }
      return _Reply(
        builder.takeBytes(),
        response.headers.value(HttpHeaders.etagHeader),
      );
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
    _active?.cancel();
    _client?.close(force: true);
  }
}

class _Reply {
  const _Reply(this.bytes, this.etag);
  final Uint8List bytes;
  final String? etag;
}

Uri _origin(Uri value) {
  if (value.host.isEmpty ||
      value.userInfo.isNotEmpty ||
      value.hasQuery ||
      value.hasFragment ||
      !{'', '/'}.contains(value.path) ||
      !(value.scheme == 'https' ||
          value.scheme == 'http' &&
              {'localhost', '127.0.0.1', '::1'}.contains(value.host))) {
    throw ArgumentError.value(value, 'base');
  }
  return Uri.parse(value.origin);
}

bool _digest(Object? value) =>
    value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
Map<String, dynamic> _object(List<int> bytes) =>
    LocalPackManifest.object(jsonDecode(utf8.decode(bytes)));
void _record(Map<String, dynamic> value, Set<String> keys) =>
    LocalPackManifest.record(value, keys);
List<String> _strings(Object? value) {
  if (value is! List ||
      value.any((v) => v is! String) ||
      value.toSet().length != value.length) {
    throw const PackDownloadFailure('corrupt');
  }
  return value.cast<String>();
}

Map<String, Map<String, dynamic>> _rows(Object? value, String key) {
  if (value is! List) throw const PackDownloadFailure('corrupt');
  final rows = <String, Map<String, dynamic>>{};
  for (final raw in value) {
    final row = LocalPackManifest.object(raw);
    if (row[key] is! String || rows.containsKey(row[key])) {
      throw const PackDownloadFailure('corrupt');
    }
    rows[row[key] as String] = row;
  }
  return rows;
}
