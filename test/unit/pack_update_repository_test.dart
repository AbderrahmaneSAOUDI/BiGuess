import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:biguess/data/download/pack_download_repository.dart';
import 'package:biguess/data/local/local_content_runtime.dart';
import 'package:biguess/data/local/local_pack_file.dart';
import 'package:biguess/data/local/local_pack_store.dart';
import 'package:biguess/data/updates/pack_update_repository.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;

class _NoSpace extends PackStorageIo {
  @override
  Future<void> write(File file, List<int> bytes) async {
    throw FileSystemException(
      'No space left',
      file.path,
      const OSError('', 28),
    );
  }
}

void main() {
  late Directory temp;
  late LocalPackStore store;
  late HttpServer server;
  late Uri origin;
  late HttpPackUpdateRepository repository;
  late Map<String, dynamic> baseManifest, targetManifest, delta, receipt;
  late String keyId, publicKey;
  late Map<String, Uint8List> objects;
  late InstalledLocalPack original;
  final requests = <String>[];
  final posted = <Map<String, dynamic>>[];
  final objectTransfers = <String>[];
  var objectBytes = 0;
  var mode = '';
  Completer<void>? arrived;
  List<Map<String, dynamic>>? revisionResults;

  Future<Uint8List> encode(
    Map<String, dynamic> manifest,
    Map<String, Uint8List> bytes,
  ) async {
    final zip = Archive();
    for (final entry in {
      'manifest.json': Uint8List.fromList(
        utf8.encode(LocalPackManifest.canonicalJson(manifest)),
      ),
      ...bytes,
    }.entries) {
      zip.add(
        ArchiveFile(entry.key, entry.value.length, entry.value)
          ..compression = CompressionType.none
          ..mode = 0x81a4,
      );
    }
    return Uint8List.fromList(ZipEncoder().encodeBytes(zip));
  }

  HttpPackUpdateRepository make({
    Map<String, String>? pins,
    PackStorageIo? io,
  }) => HttpPackUpdateRepository(
    base: origin,
    store: io == null ? store : LocalPackStore(store.root, io: io),
    pinnedKeys: pins ?? {keyId: publicKey},
    requestTimeout: const Duration(seconds: 2),
  );
  Matcher failure(String code) =>
      throwsA(isA<PackDownloadFailure>().having((e) => e.code, 'code', code));
  Map<String, dynamic> copy(Map<String, dynamic> value) =>
      jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  Future<void> assertPrevious() async {
    final reopened = await LocalPackStore(
      store.root,
    ).readInstalled('fixture-pack');
    expect(reopened!.manifest.digest, original.manifest.digest);
    expect(reopened.directory.path, original.directory.path);
    expect(reopened.cards.length, 100);
    expect(
      (await store.root
          .list()
          .where((e) => p.basename(e.path).startsWith('download-'))
          .toList()),
      isEmpty,
    );
  }

  setUp(() async {
    requests.clear();
    posted.clear();
    objectTransfers.clear();
    objectBytes = 0;
    mode = '';
    arrived = null;
    revisionResults = null;
    temp = await Directory.systemTemp.createTemp('incremental-pack-');
    store = LocalPackStore(Directory('${temp.path}/packs'));
    final fixture = LocalPackFile.decode(
      await File('test/fixtures/local_pack/colors.biguesspack').readAsBytes(),
      const PackImportLimits(),
    ).manifest.toJson();
    objects = {};
    final cards = <Map<String, dynamic>>[],
        descriptors = <Map<String, dynamic>>[],
        rights = <Map<String, dynamic>>[];
    for (var i = 0; i < 105; i++) {
      final bitmap = image.Image(width: 8, height: 8)
        ..setPixelRgba(0, 0, i, i * 2 % 256, i * 3 % 256, 255);
      final bytes = Uint8List.fromList(image.encodePng(bitmap));
      final hash = hashes.sha256.convert(bytes).toString();
      final key = 'objects/$hash.png';
      objects[key] = bytes;
      cards.add({
        'id': 'card-$i',
        'packId': 'fixture-pack',
        'name': 'Card $i',
        'imageReference': key,
        'difficulty': 1,
      });
      descriptors.add({
        'key': key,
        'sha256': hash,
        'sizeBytes': bytes.length,
        'mediaType': 'image/png',
      });
      rights.add({
        ...fixture['provenance']['cardRights'][0] as Map<String, dynamic>,
        'id': 'card-$i',
      });
    }
    Map<String, dynamic> manifest(int count, int revision) => {
      'schemaVersion': 1,
      'kind': 'full',
      'topic': fixture['topic'],
      'pack': {
        ...fixture['pack'] as Map<String, dynamic>,
        'revision': revision,
      },
      'cards': cards.take(count).toList(),
      'objects': descriptors.take(count).toList(),
      'provenance': {
        'mode': 'cleared-test',
        'packRights': fixture['provenance']['packRights'],
        'cardRights': rights.take(count).toList(),
      },
    };
    baseManifest = manifest(100, 1);
    targetManifest = manifest(105, 2);
    final baseBytes = await encode(baseManifest, {
      for (final descriptor in descriptors.take(100))
        descriptor['key'] as String: objects[descriptor['key']]!,
    });
    final source = await File(
      '${temp.path}/base.biguesspack',
    ).writeAsBytes(baseBytes);
    original = await store.install(source);
    final key = await Ed25519().newKeyPairFromSeed(
      List.generate(32, (i) => i + 1),
    );
    final raw = await key.extractPublicKey();
    final spki = [
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
      ...raw.bytes,
    ];
    keyId = hashes.sha256.convert(spki).toString();
    publicKey = base64.encode(spki);
    final manifestBytes = utf8.encode(
      LocalPackManifest.canonicalJson(targetManifest),
    );
    final archiveBytes = await encode(targetManifest, objects);
    final statement = {
      'archiveSha256': hashes.sha256.convert(archiveBytes).toString(),
      'archiveSizeBytes': archiveBytes.length,
      'domain': 'biguess-pack-publication-v1',
      'manifestSha256': hashes.sha256.convert(manifestBytes).toString(),
      'manifestSizeBytes': manifestBytes.length,
      'packId': 'fixture-pack',
      'revision': 2,
      'topicId': 'fixture-topic',
    };
    final signature = await Ed25519().sign(
      utf8.encode('${jsonEncode(statement)}\n'),
      keyPair: key,
    );
    receipt = {
      'schemaVersion': 1,
      'algorithm': 'Ed25519',
      'keyId': keyId,
      'statement': statement,
      'signature': base64.encode(signature.bytes),
    };
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = Uri.parse('http://127.0.0.1:${server.port}');
    delta = {
      'protocolVersion': 1,
      'packId': 'fixture-pack',
      'fromRevision': 1,
      'toRevision': 2,
      'targetManifestSha256': statement['manifestSha256'],
      'targetManifestUrl':
          '$origin/content/v1/packs/fixture-pack/revisions/2/manifest',
      'upsertCards': cards.skip(100).toList(),
      'removeCardIds': <String>[],
      'objects': descriptors.skip(100).toList(),
      'manifestPatch': {
        'topic': targetManifest['topic'],
        'pack': targetManifest['pack'],
        'provenanceMode': 'cleared-test',
        'packRights': targetManifest['provenance']['packRights'],
        'upsertCardRights': rights.skip(100).toList(),
        'cardOrder': cards.map((c) => c['id']).toList(),
        'objectOrder': descriptors.map((d) => d['key']).toList(),
      },
    };
    server.listen((request) async {
      requests.add(request.uri.toString());
      expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
      expect(request.headers.value(HttpHeaders.cookieHeader), isNull);
      final response = request.response;
      try {
        if (mode == 'offline') {
          response.statusCode = 503;
        } else if (request.uri.path == '/content/v1/sync/revisions') {
          posted.add(
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>,
          );
          response.headers.contentType = ContentType.json;
          if (mode == 'cancel-check') {
            response.write('{"protocolVersion":1,');
            await response.flush();
            arrived?.complete();
            await response.done;
            return;
          }
          response.write(
            jsonEncode({
              'protocolVersion': 1,
              'results':
                  revisionResults ??
                  [
                    {
                      'packId': 'fixture-pack',
                      'status': mode == 'unchanged'
                          ? 'unchanged'
                          : 'updateAvailable',
                      'revision': mode == 'unchanged' ? 1 : 2,
                      'manifestSha256': mode == 'unchanged'
                          ? original.manifest.digest
                          : statement['manifestSha256'],
                    },
                  ],
            }),
          );
        } else if (request.uri.path.endsWith('/delta')) {
          expect(request.uri.queryParameters, {
            'fromRevision': '1',
            'toRevision': '2',
            'includeManifestPatch': '1',
          });
          if (mode == 'history-missing') {
            response.statusCode = 409;
          } else {
            final wire = copy(delta);
            if (mode == 'rights-tamper') {
              wire['manifestPatch']['upsertCardRights'][0]['attribution'] =
                  'Tampered';
            }
            if (mode == 'order-tamper') {
              final order = wire['manifestPatch']['cardOrder'] as List;
              final first = order[0];
              order[0] = order[1];
              order[1] = first;
            }
            if (mode == 'metadata-tamper') {
              wire['upsertCards'][0]['name'] = 'Tampered';
            }
            final body = utf8.encode(jsonEncode(wire));
            response.headers.contentType = ContentType.json;
            response.headers.set(
              HttpHeaders.etagHeader,
              '"${hashes.sha256.convert(body)}"',
            );
            response.add(body);
          }
        } else if (request.uri.path.endsWith('/signature')) {
          final wire = copy(receipt);
          if (mode == 'signature-tamper') {
            wire['signature'] = base64.encode(List<int>.filled(64, 0));
          }
          response.write(jsonEncode(wire));
        } else if (request.uri.path.contains('/objects/')) {
          final key = request.uri.path.split('/revisions/2/').last;
          objectTransfers.add(key);
          final bytes = objects[key]!;
          if (mode == 'cancel-stream') {
            response.add(bytes.take(bytes.length ~/ 2).toList());
            await response.flush();
            arrived?.complete();
            await response.done;
            return;
          }
          final sent = mode == 'object-tamper'
              ? [...bytes.take(bytes.length - 1), bytes.last ^ 1]
              : mode == 'partial'
              ? bytes.take(bytes.length ~/ 2).toList()
              : bytes;
          objectBytes += sent.length;
          response.add(sent);
        } else {
          response.statusCode = 500;
        }
        await response.close();
      } catch (_) {
        /* Deliberate cancellation closes the response. */
      }
    });
    repository = make();
  });
  tearDown(() async {
    repository.close();
    await server.close(force: true);
    await temp.delete(recursive: true);
  });

  test(
    'manual check is tiny; 100 to105 downloads five changed Cards/images and reopens offline',
    () async {
      expect(requests, isEmpty);
      final statuses = await repository.check();
      expect(statuses.single.state, PackUpdateAvailability.updateAvailable);
      expect(posted.single, {
        'protocolVersion': 1,
        'packs': [
          {'packId': 'fixture-pack', 'revision': 1},
        ],
      });
      expect(requests.length, 1);
      expect(
        (await store.readInstalled('fixture-pack'))!.manifest.pack.revision,
        1,
      );
      final progress = <PackDownloadProgress>[];
      final result = await repository.update(
        statuses.single,
        onProgress: progress.add,
      );
      expect(result.cards.length, 105);
      expect(result.manifest.pack.revision, 2);
      expect(objectTransfers.length, 5);
      expect(
        objectTransfers,
        (delta['objects'] as List).map((d) => d['key']).toList(),
      );
      expect(
        objectBytes,
        (delta['objects'] as List).fold<int>(
          0,
          (n, d) => n + (d['sizeBytes'] as int),
        ),
      );
      expect(
        requests.any(
          (p) => p.endsWith('/manifest') || p.endsWith('/archive.biguesspack'),
        ),
        isFalse,
      );
      expect(progress.last.phase, PackDownloadPhase.installing);
      repository.close();
      await server.close(force: true);
      final runtime = await LocalContentRuntime.open(supportDirectory: temp);
      expect(runtime.usesSqlite, isTrue);
      expect(
        runtime.repository.getInstalledCardsForPack('fixture-pack')!.length,
        105,
      );
      runtime.close();
    },
  );

  test(
    'unchanged revision check transfers no manifest, receipt or images',
    () async {
      mode = 'unchanged';
      final statuses = await repository.check();
      expect(statuses.single.state, PackUpdateAvailability.upToDate);
      expect(requests, ['/content/v1/sync/revisions']);
      await assertPrevious();
    },
  );

  for (final broken in [
    'metadata-tamper',
    'rights-tamper',
    'order-tamper',
    'signature-tamper',
    'object-tamper',
    'partial',
  ]) {
    test(
      '$broken fails closed and preserves prior installed generation',
      () async {
        final status = (await repository.check()).single;
        mode = broken;
        await expectLater(repository.update(status), failure('corrupt'));
        await assertPrevious();
        mode = '';
        expect((await repository.update(status)).cards.length, 105);
      },
    );
  }

  test('untrusted pins fail before any object transfers', () async {
    final status = (await repository.check()).single;
    repository.close();
    repository = make(pins: {});
    await expectLater(repository.update(status), failure('untrusted-key'));
    expect(objectTransfers, isEmpty);
    await assertPrevious();
  });

  test(
    'HTTP outage and missing history never replace installed revision',
    () async {
      final status = (await repository.check()).single;
      mode = 'offline';
      await expectLater(repository.check(), failure('offline'));
      await assertPrevious();
      mode = 'history-missing';
      await expectLater(
        repository.update(status),
        failure('delta-unavailable'),
      );
      await assertPrevious();
    },
  );

  test(
    'cancelled streaming update removes staging and explicit retry starts fresh',
    () async {
      final status = (await repository.check()).single;
      mode = 'cancel-stream';
      arrived = Completer<void>();
      final token = PackDownloadCancellation();
      final pending = repository.update(status, cancellation: token);
      final rejected = expectLater(pending, failure('cancelled'));
      await arrived!.future.timeout(const Duration(seconds: 2));
      token.cancel();
      await rejected;
      await assertPrevious();
      mode = '';
      expect((await repository.update(status)).cards.length, 105);
    },
  );

  test(
    'storage full and preactivation cancel leave old content playable',
    () async {
      final status = (await repository.check()).single;
      repository.close();
      repository = make(io: _NoSpace());
      await expectLater(repository.update(status), failure('no-space'));
      await assertPrevious();
      repository.close();
      repository = make();
      final token = PackDownloadCancellation();
      await expectLater(
        repository.update(
          status,
          cancellation: token,
          onProgress: (p) {
            if (p.phase == PackDownloadPhase.installing) token.cancel();
          },
        ),
        failure('cancelled'),
      );
      await assertPrevious();
    },
  );

  test(
    'a locally changed base invalidates old update status rather than overwriting',
    () async {
      final status = (await repository.check()).single;
      await repository.update(status);
      final count = requests.length;
      await expectLater(repository.update(status), failure('catalog-changed'));
      expect(requests.length, count);
    },
  );
  Future<File> developmentPack() async {
    final manifest = copy(baseManifest);
    manifest['topic']['id'] = 'private-owner-topic';
    manifest['pack']['id'] = 'private-legacy-pack';
    manifest['pack']['topicId'] = 'private-owner-topic';
    for (final card in manifest['cards'] as List) {
      card['id'] = 'private-${card['id']}';
      card['packId'] = 'private-legacy-pack';
    }
    manifest['provenance'] = {
      'mode': 'legacy-development',
      'packRights': {
        'rights_status': 'unverified',
        'permission_to_publish': false,
        'public_test_publishable': false,
      },
      'cardRights': <Object>[],
    };
    final bytes = await encode(manifest, {
      for (final descriptor in manifest['objects'] as List)
        descriptor['key'] as String: objects[descriptor['key']]!,
    });
    return File(
      '${temp.path}/private-development.biguesspack',
    ).writeAsBytes(bytes);
  }

  test(
    'local-only development generations make no anonymous check or update request',
    () async {
      final privateStore = LocalPackStore(
        Directory('${temp.path}/private-only'),
      );
      final installed = await privateStore.install(await developmentPack());
      repository.close();
      repository = HttpPackUpdateRepository(
        base: origin,
        store: privateStore,
        pinnedKeys: {keyId: publicKey},
      );
      expect(await repository.check(), isEmpty);
      const target = PackUpdateStatus(
        packId: 'private-legacy-pack',
        installedRevision: 1,
        state: PackUpdateAvailability.updateAvailable,
        revision: 2,
        manifestSha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      await expectLater(repository.update(target), failure('unavailable'));
      expect(requests, isEmpty);
      expect(posted, isEmpty);
      expect(
        (await privateStore.readInstalled(
          'private-legacy-pack',
        ))!.manifest.digest,
        installed.manifest.digest,
      );
    },
  );

  test(
    'mixed private imports and cleared downloads disclose only cleared installed IDs',
    () async {
      await store.install(await developmentPack());
      expect((await repository.check()).single.packId, 'fixture-pack');
      expect(posted.single, {
        'protocolVersion': 1,
        'packs': [
          {'packId': 'fixture-pack', 'revision': 1},
        ],
      });
      expect(jsonEncode(posted), isNot(contains('private-legacy-pack')));
      expect(jsonEncode(posted), isNot(contains('private-owner-topic')));
    },
  );
  Map<String, dynamic> deletion({
    String packId = 'fixture-pack',
    Object revision = 3,
    Object deletedAt = '2026-11-12T12:00:00.000Z',
    Object reason = 'administrative_deletion',
  }) => {
    'packId': packId,
    'status': 'deleted',
    'tombstone': {
      'packId': packId,
      'revision': revision,
      'deletedAt': deletedAt,
      'reason': reason,
    },
  };

  test(
    'a newer exact tombstone is exposed with trusted origin but check never retires content',
    () async {
      revisionResults = [deletion()];
      final status = (await repository.check()).single;
      expect(status.state, PackUpdateAvailability.deleted);
      expect(status.installedRevision, 1);
      expect(status.revision, 3);
      expect(status.tombstone!.packId, 'fixture-pack');
      expect(status.tombstone!.revision, 3);
      expect(status.tombstone!.deletedAt, DateTime.utc(2026, 11, 12, 12));
      expect(status.tombstone!.sourceOrigin, origin.origin);
      expect(status.tombstone!.reason, 'administrative_deletion');
      await assertPrevious();
      expect(requests, ['/content/v1/sync/revisions']);
    },
  );

  test(
    'unavailable and unknown statuses never invent a tombstone or retire files',
    () async {
      for (final state in ['unavailable', 'unknown']) {
        revisionResults = [
          {'packId': 'fixture-pack', 'status': state},
        ];
        final status = (await repository.check()).single;
        expect(status.tombstone, isNull);
        expect(
          status.state,
          state == 'unavailable'
              ? PackUpdateAvailability.unavailable
              : PackUpdateAvailability.unknown,
        );
        await assertPrevious();
      }
    },
  );

  final invalidDeletions = <String, Map<String, dynamic> Function()>{
    'stale revision': () => deletion(revision: 1),
    'fractional revision': () => deletion(revision: 3.0),
    'wrong Pack': () => {
      ...deletion(),
      'tombstone': {
        ...deletion()['tombstone'] as Map<String, dynamic>,
        'packId': 'guessed-other',
      },
    },
    'local date': () => deletion(deletedAt: '2026-11-12T12:00:00'),
    'offset date': () => deletion(deletedAt: '2026-11-12T13:00:00+01:00'),
    'overflow date': () => deletion(deletedAt: '2026-02-30T12:00:00Z'),
    'overflow time': () => deletion(deletedAt: '2026-11-12T24:00:00Z'),
    'wrong reason': () => deletion(reason: 'catalog_absence'),
    'forged origin': () => {
      ...deletion(),
      'tombstone': {
        ...deletion()['tombstone'] as Map<String, dynamic>,
        'sourceOrigin': 'https://evil.example',
      },
    },
  };
  for (final entry in invalidDeletions.entries) {
    test(
      'invalid authoritative deletion ${entry.key} preserves installed content',
      () async {
        revisionResults = [entry.value()];
        await expectLater(repository.check(), failure('corrupt'));
        await assertPrevious();
      },
    );
  }

  Future<InstalledLocalPack> secondPublicPack() async {
    final manifest = copy(baseManifest);
    manifest['pack']['id'] = 'other-pack';
    for (final card in manifest['cards'] as List) {
      card['id'] = 'other-${card['id']}';
      card['packId'] = 'other-pack';
    }
    for (final rights in manifest['provenance']['cardRights'] as List) {
      rights['id'] = 'other-${rights['id']}';
    }
    final source = await File('${temp.path}/other-public.biguesspack')
        .writeAsBytes(
          await encode(manifest, {
            for (final descriptor in manifest['objects'] as List)
              descriptor['key'] as String: objects[descriptor['key']]!,
          }),
        );
    return store.install(source);
  }

  test(
    'a malformed later result cannot expose a partially valid tombstone list',
    () async {
      final other = await secondPublicPack();
      final validFirst = deletion();
      final unknownOther = {'packId': 'other-pack', 'status': 'unknown'};
      final cases = <List<Map<String, dynamic>>>[
        [validFirst],
        [validFirst, validFirst],
        [unknownOther, validFirst],
        [validFirst, deletion(packId: 'other-pack', revision: 1)],
      ];
      for (final invalid in cases) {
        revisionResults = invalid;
        await expectLater(repository.check(), failure('corrupt'));
        await assertPrevious();
        expect(
          (await store.readInstalled('other-pack'))!.manifest.digest,
          other.manifest.digest,
        );
      }
    },
  );

  test(
    'cancelled incomplete Home sync returns no deletion result and keeps prior files',
    () async {
      mode = 'cancel-check';
      arrived = Completer<void>();
      final token = PackDownloadCancellation();
      final pending = repository.check(cancellation: token);
      final rejected = expectLater(pending, failure('cancelled'));
      await arrived!.future.timeout(const Duration(seconds: 2));
      token.cancel();
      await rejected;
      await assertPrevious();
      expect(posted.length, 1);
    },
  );
  test(
    'manual sync includes a user-removed public identity and exposes later deletion without applying it',
    () async {
      await store.removeDownload(
        'fixture-pack',
        expectedRevision: 1,
        expectedDigest: original.manifest.digest,
      );
      expect(await store.readInstalled('fixture-pack'), isNull);
      revisionResults = [deletion()];
      final status = (await repository.check()).single;
      expect(posted.single['packs'], [
        {'packId': 'fixture-pack', 'revision': 1},
      ]);
      expect(status.installedRevision, 1);
      expect(status.tombstone!.revision, 3);
      final removed = (await store.readRetirements()).single;
      expect(removed.publicSyncEligible, isTrue);
      expect(removed.tombstone, isNull);
      expect(await store.readInstalled('fixture-pack'), isNull);
    },
  );

  test(
    'user-removed local-only identities are excluded from mixed public checks',
    () async {
      final private = await store.install(await developmentPack());
      await store.removeDownload(
        'private-legacy-pack',
        expectedRevision: 1,
        expectedDigest: private.manifest.digest,
      );
      revisionResults = [
        {'packId': 'fixture-pack', 'status': 'unknown'},
      ];
      expect((await repository.check()).single.packId, 'fixture-pack');
      expect(posted.single['packs'], [
        {'packId': 'fixture-pack', 'revision': 1},
      ]);
      expect(jsonEncode(posted), isNot(contains('private-legacy-pack')));
      expect(
        (await store.readRetirements()).single.publicSyncEligible,
        isFalse,
      );
      await assertPrevious();
    },
  );
}
