import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:biguess/data/catalog/catalog_models.dart';
import 'package:biguess/data/download/pack_download_repository.dart';
import 'package:biguess/data/local/local_pack_file.dart';
import 'package:biguess/data/local/local_content_runtime.dart';
import 'package:biguess/data/local/local_pack_store.dart';
import 'package:biguess/data/local/private_pack_images.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _NoSpace extends PackStorageIo {
  @override
  Future<void> write(File file, List<int> bytes) async {
    throw FileSystemException(
      'No space left on device',
      file.path,
      const OSError('', 28),
    );
  }
}

void main() {
  late Directory temp;
  late HttpServer server;
  late Uri base;
  late LocalPackStore store;
  late HttpPackDownloadRepository repository;
  late Map<String, dynamic> manifest, statement, receipt, descriptor;
  late Uint8List archiveBytes, manifestBytes;
  late SimpleKeyPair key;
  late String keyId, publicKey;
  late CatalogPackSummary summary;
  final requests = <String>[];
  String? mode;

  Future<void> prepare({int revision = 1}) async {
    manifest['pack']['revision'] = revision;
    manifestBytes = Uint8List.fromList(
      utf8.encode(LocalPackManifest.canonicalJson(manifest)),
    );
    final original = LocalPackFile.decode(
      await File('test/fixtures/local_pack/colors.biguesspack').readAsBytes(),
      const PackImportLimits(),
    );
    final archive = Archive();
    for (final entry in {
      'manifest.json': manifestBytes,
      ...original.objects,
    }.entries) {
      archive.add(
        ArchiveFile(entry.key, entry.value.length, entry.value)
          ..compression = CompressionType.none
          ..mode = 0x81a4,
      );
    }
    archiveBytes = Uint8List.fromList(ZipEncoder().encodeBytes(archive));
    statement = {
      'archiveSha256': hashes.sha256.convert(archiveBytes).toString(),
      'archiveSizeBytes': archiveBytes.length,
      'domain': 'biguess-pack-publication-v1',
      'manifestSha256': hashes.sha256.convert(manifestBytes).toString(),
      'manifestSizeBytes': manifestBytes.length,
      'packId': 'fixture-pack',
      'revision': revision,
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
    final path = '${base}content/v1/packs/fixture-pack/revisions/$revision/';
    descriptor = {
      'protocolVersion': 1,
      'packId': 'fixture-pack',
      'revision': revision,
      'manifestUrl': '${path}manifest',
      'manifestSha256': statement['manifestSha256'],
      'archiveUrl': '${path}archive.biguesspack',
      'archiveSha256': statement['archiveSha256'],
      'sizeBytes': archiveBytes.length,
      'manifestSchemaVersion': 1,
    };
    summary = CatalogPackSummary(
      id: 'fixture-pack',
      topicId: 'fixture-topic',
      name: 'Original colors',
      revision: revision,
      cardCount: 2,
      manifestSha256: statement['manifestSha256'] as String,
    );
  }

  HttpPackDownloadRepository makeRepository({
    Map<String, String>? pins,
    PackStorageIo? io,
    Duration? timeout,
  }) => HttpPackDownloadRepository(
    base: base,
    store: io == null ? store : LocalPackStore(store.root, io: io),
    pinnedKeys: pins ?? {keyId: publicKey},
    requestTimeout: timeout ?? const Duration(seconds: 2),
  );

  Matcher failure(String code) =>
      throwsA(isA<PackDownloadFailure>().having((e) => e.code, 'code', code));

  setUp(() async {
    requests.clear();
    mode = null;
    temp = await Directory.systemTemp.createTemp('pack-download-test-');
    store = LocalPackStore(Directory('${temp.path}/packs'));
    key = await Ed25519().newKeyPairFromSeed(List.generate(32, (i) => i));
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
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}/');
    final fixture = LocalPackFile.decode(
      await File('test/fixtures/local_pack/colors.biguesspack').readAsBytes(),
      const PackImportLimits(),
    );
    manifest = fixture.manifest.toJson();
    await prepare();
    server.listen((request) async {
      requests.add(request.uri.path);
      expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
      expect(request.headers.value(HttpHeaders.cookieHeader), isNull);
      final response = request.response;
      try {
        if (mode == 'timeout') {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        if (mode == 'redirect') {
          response.statusCode = 302;
          response.headers.set(HttpHeaders.locationHeader, '${base}stolen');
        } else if (mode == 'unpublished') {
          response.statusCode = 403;
        } else if (request.uri.path.endsWith('/download')) {
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode(descriptor));
        } else if (request.uri.path.endsWith('/signature')) {
          response.write(jsonEncode(receipt));
        } else if (request.uri.path.endsWith('/manifest')) {
          response.add(
            mode == 'manifest-corrupt'
                ? manifestBytes.sublist(1)
                : manifestBytes,
          );
        } else if (request.uri.path.endsWith('/archive.biguesspack')) {
          if (mode == 'slow-archive') {
            response.add(archiveBytes.sublist(0, archiveBytes.length ~/ 2));
            await response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 150));
            response.add(archiveBytes.sublist(archiveBytes.length ~/ 2));
          } else if (mode == 'partial') {
            response.add(archiveBytes.sublist(0, archiveBytes.length ~/ 2));
          } else if (mode == 'archive-corrupt') {
            response.add([
              ...archiveBytes.take(archiveBytes.length - 1),
              archiveBytes.last ^ 1,
            ]);
          } else {
            response.add(archiveBytes);
          }
        } else {
          response.statusCode = 404;
        }
        await response.close();
      } catch (_) {
        // Client may abort a deliberately delayed/failed response.
      }
    });
    repository = makeRepository();
  });

  tearDown(() async {
    repository.close();
    await server.close(force: true);
    await temp.delete(recursive: true);
  });

  test(
    'published cleared fixture verifies, installs privately and survives offline restart',
    () async {
      final progress = <PackDownloadProgress>[];
      final installed = await repository.download(
        summary,
        onProgress: progress.add,
      );
      expect(
        progress.map((p) => p.phase),
        containsAllInOrder(PackDownloadPhase.values),
      );
      expect(progress.last.receivedBytes, archiveBytes.length);
      expect(installed.manifest.digest, summary.manifestSha256);
      expect(requests.length, 4);
      repository.close();
      await server.close(force: true);
      final reopened = await LocalPackStore(
        store.root,
      ).readInstalled(summary.id);
      expect(reopened!.cards.length, 2);
      for (final card in reopened.cards) {
        expect(
          await PrivatePackImages.read(
            store.root,
            PrivateImageReference.parse(card.imageReference),
          ),
          isNotEmpty,
        );
      }
      expect(
        await store.root
            .list()
            .where((e) => p.basename(e.path).startsWith('download-'))
            .toList(),
        isEmpty,
      );
      final runtime = await LocalContentRuntime.open(supportDirectory: temp);
      try {
        expect(runtime.failure, isNull);
        expect(runtime.usesSqlite, isTrue);
        final projected = runtime.repository.getInstalledCardsForPack(
          summary.id,
        );
        expect(projected, reopened.cards);
        expect(projected!.map((card) => card.name), ['Red', 'Blue']);
        for (final card in projected) {
          expect(card.imageReference, startsWith('biguess-pack:'));
          expect(
            await PrivatePackImages.read(
              store.root,
              PrivateImageReference.parse(card.imageReference),
            ),
            isNotEmpty,
          );
        }
        expect(
          requests.length,
          4,
          reason: 'Offline runtime projection must use committed private files',
        );
      } finally {
        runtime.close();
      }
    },
  );

  test(
    'cancellation aborts an in-flight update, cleans temp and preserves prior content',
    () async {
      final previous = await repository.download(summary);
      await prepare(revision: 2);
      mode = 'slow-archive';
      final cancellation = PackDownloadCancellation();
      await expectLater(
        repository.download(
          summary,
          cancellation: cancellation,
          onProgress: (progress) {
            if (progress.phase == PackDownloadPhase.downloading &&
                progress.receivedBytes > 0) {
              cancellation.cancel();
            }
          },
        ),
        failure('cancelled'),
      );
      expect(
        (await store.readInstalled(summary.id))!.directory.path,
        previous.directory.path,
      );
      expect(
        await store.root
            .list()
            .where((e) => p.basename(e.path).startsWith('download-'))
            .toList(),
        isEmpty,
      );
      mode = null;
      expect((await repository.download(summary)).manifest.pack.revision, 2);
    },
  );

  test(
    'cancel before activation never commits; pre-cancelled jobs make no HTTP request',
    () async {
      final token = PackDownloadCancellation()..cancel();
      await expectLater(
        repository.download(summary, cancellation: token),
        failure('cancelled'),
      );
      expect(requests, isEmpty);
      final previous = await repository.download(summary);
      await prepare(revision: 2);
      final installing = PackDownloadCancellation();
      await expectLater(
        repository.download(
          summary,
          cancellation: installing,
          onProgress: (progress) {
            if (progress.phase == PackDownloadPhase.installing) {
              installing.cancel();
            }
          },
        ),
        failure('cancelled'),
      );
      expect(
        (await store.readInstalled(summary.id))!.directory.path,
        previous.directory.path,
      );
      expect(
        await store.root
            .list()
            .where((e) => p.basename(e.path).startsWith('download-'))
            .toList(),
        isEmpty,
      );
    },
  );

  for (final broken in ['manifest-corrupt', 'archive-corrupt', 'partial']) {
    test(
      '$broken fails without activating or destroying previous revision and retry succeeds',
      () async {
        final previous = await repository.download(summary);
        await prepare(revision: 2);
        mode = broken;
        await expectLater(repository.download(summary), failure('corrupt'));
        expect(
          (await LocalPackStore(
            store.root,
          ).readInstalled(summary.id))!.directory.path,
          previous.directory.path,
        );
        expect(
          await store.root
              .list()
              .where((e) => p.basename(e.path).startsWith('download-'))
              .toList(),
          isEmpty,
        );
        mode = null;
        expect((await repository.download(summary)).manifest.pack.revision, 2);
      },
    );
  }

  test(
    'unknown key and invalid pinned SPKI fail before archive bytes',
    () async {
      repository.close();
      repository = makeRepository(pins: {});
      await expectLater(repository.download(summary), failure('untrusted-key'));
      expect(
        requests.any(
          (p) => p.endsWith('manifest') || p.endsWith('archive.biguesspack'),
        ),
        isFalse,
      );
      repository.close();
      repository = makeRepository(
        pins: {keyId: base64.encode(List.filled(44, 0))},
      );
      await expectLater(repository.download(summary), failure('untrusted-key'));
      expect(await store.readInstalled(summary.id), isNull);
    },
  );

  test(
    'tampered signature is rejected before manifest and archive requests',
    () async {
      receipt['signature'] = base64.encode(List.filled(64, 0));
      await expectLater(repository.download(summary), failure('corrupt'));
      expect(requests.length, 2);
      expect(await store.readInstalled(summary.id), isNull);
    },
  );

  for (final field in ['archiveSizeBytes', 'manifestSizeBytes']) {
    test('signed wrong $field fails before activation', () async {
      statement[field] = (statement[field] as int) + 1;
      descriptor['sizeBytes'] = statement['archiveSizeBytes'];
      final signature = await Ed25519().sign(
        utf8.encode('${jsonEncode(statement)}\n'),
        keyPair: key,
      );
      receipt['signature'] = base64.encode(signature.bytes);
      await expectLater(repository.download(summary), failure('corrupt'));
      expect(await store.readInstalled(summary.id), isNull);
    });
  }

  test('partial first download never makes a Pack playable', () async {
    mode = 'partial';
    await expectLater(repository.download(summary), failure('corrupt'));
    expect(await LocalPackStore(store.root).readInstalled(summary.id), isNull);
    expect(
      await store.root
          .list()
          .where((e) => p.basename(e.path).startsWith('download-'))
          .toList(),
      isEmpty,
    );
  });

  test(
    'cross-origin descriptor and changed catalog revision fail closed',
    () async {
      descriptor['archiveUrl'] = 'https://other.example/archive.biguesspack';
      await expectLater(repository.download(summary), failure('corrupt'));
      await prepare(revision: 2);
      final stale = CatalogPackSummary(
        id: summary.id,
        topicId: summary.topicId,
        name: summary.name,
        revision: 1,
        cardCount: 2,
        manifestSha256: summary.manifestSha256,
      );
      await expectLater(repository.download(stale), failure('catalog-changed'));
      expect(await store.readInstalled(summary.id), isNull);
    },
  );

  test('unpublished and redirects are never downloaded', () async {
    mode = 'unpublished';
    await expectLater(repository.download(summary), failure('unavailable'));
    mode = 'redirect';
    await expectLater(repository.download(summary), failure('offline'));
    expect(requests.any((p) => p.endsWith('stolen')), isFalse);
  });

  test(
    'timeout and backend outage preserve the previous installed revision',
    () async {
      final previous = await repository.download(summary);
      repository.close();
      repository = makeRepository(timeout: const Duration(milliseconds: 20));
      mode = 'timeout';
      await expectLater(repository.download(summary), failure('timeout'));
      await server.close(force: true);
      await expectLater(repository.download(summary), failure('offline'));
      expect(
        (await store.readInstalled(summary.id))!.directory.path,
        previous.directory.path,
      );
    },
  );

  test(
    'no-space activation failure leaves previous revision and removes download temp',
    () async {
      final previous = await repository.download(summary);
      await prepare(revision: 2);
      repository.close();
      repository = makeRepository(io: _NoSpace());
      await expectLater(repository.download(summary), failure('no-space'));
      expect(
        (await store.readInstalled(summary.id))!.directory.path,
        previous.directory.path,
      );
      expect(
        await store.root
            .list()
            .where((e) => p.basename(e.path).startsWith('download-'))
            .toList(),
        isEmpty,
      );
    },
  );

  test(
    'signed archive must contain the exact signed external manifest',
    () async {
      // A valid signature over an unrelated archive cannot install different Cards.
      manifest['pack']['name'] = 'Signed but different metadata';
      manifestBytes = Uint8List.fromList(
        utf8.encode(LocalPackManifest.canonicalJson(manifest)),
      );
      statement['manifestSha256'] = hashes.sha256
          .convert(manifestBytes)
          .toString();
      statement['manifestSizeBytes'] = manifestBytes.length;
      final signed = await Ed25519().sign(
        utf8.encode('${jsonEncode(statement)}\n'),
        keyPair: key,
      );
      receipt['signature'] = base64.encode(signed.bytes);
      descriptor['manifestSha256'] = statement['manifestSha256'];
      summary = CatalogPackSummary(
        id: summary.id,
        topicId: summary.topicId,
        name: summary.name,
        revision: summary.revision,
        cardCount: 2,
        manifestSha256: statement['manifestSha256'] as String,
      );
      await expectLater(repository.download(summary), failure('corrupt'));
      expect(await store.readInstalled(summary.id), isNull);
    },
  );
}
