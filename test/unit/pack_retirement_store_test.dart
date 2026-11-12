import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:biguess/data/local/local_pack_file.dart';
import 'package:biguess/data/local/local_pack_store.dart';
import 'package:biguess/data/local/pack_tombstone.dart';
import 'package:biguess/data/local/private_pack_images.dart';
import 'package:flutter_test/flutter_test.dart';

class _FailRetirement extends PackStorageIo {
  _FailRetirement({this.writeFailure = false, this.activateFailure = false});
  final bool writeFailure, activateFailure;
  @override
  Future<void> write(File file, List<int> bytes) async {
    if (writeFailure) {
      throw FileSystemException(
        'No space left on device',
        file.path,
        const OSError('', 28),
      );
    }
    return super.write(file, bytes);
  }

  @override
  Future<void> activate(File pending, File active) async {
    if (activateFailure) {
      throw FileSystemException('Rename failed', active.path);
    }
    return super.activate(pending, active);
  }
}

void main() {
  late Directory temp;
  late LocalPackStore store;
  late File source;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('pack-retirement-');
    store = LocalPackStore(Directory('${temp.path}/packs'));
    source = File('test/fixtures/local_pack/colors.biguesspack');
  });
  tearDown(() => temp.delete(recursive: true));
  PackTombstone deleted(String id, {int revision = 2}) => PackTombstone(
    packId: id,
    revision: revision,
    deletedAt: DateTime.utc(2026, 11, 12),
    sourceOrigin: 'https://content.example',
  );

  Future<File> fixture(String id, {int revision = 1}) async {
    final archive = ZipDecoder().decodeBytes(await source.readAsBytes());
    final json =
        jsonDecode(utf8.decode(archive.find('manifest.json')!.content))
            as Map<String, dynamic>;
    json['pack']['id'] = id;
    json['pack']['revision'] = revision;
    for (final card in json['cards'] as List) {
      card['packId'] = id;
      card['id'] = '$id-${card['id']}';
    }
    for (final rights in json['provenance']['cardRights'] as List) {
      rights['id'] = '$id-${rights['id']}';
    }
    final output = Archive();
    for (final file in archive.files) {
      final bytes = file.name == 'manifest.json'
          ? utf8.encode(LocalPackManifest.canonicalJson(json))
          : file.content;
      output.add(
        ArchiveFile(file.name, bytes.length, bytes)
          ..compression = CompressionType.none
          ..mode = 0x81a4,
      );
    }
    return File(
      '${temp.path}/$id-$revision.biguesspack',
    ).writeAsBytes(ZipEncoder().encodeBytes(output));
  }

  test(
    'user removal frees a slot, retains metadata and permits same-revision redownload',
    () async {
      final first = await store.install(source);
      await store.removeDownload(
        'fixture-pack',
        expectedRevision: 1,
        expectedDigest: first.manifest.digest,
      );
      expect(await store.readInstalled('fixture-pack'), isNull);
      expect(await store.readAllInstalled(), isEmpty);
      final record = (await store.readRetirements()).single;
      expect(record.publicSyncEligible, isTrue);
      expect(record.tombstone, isNull);
      expect(record.name, 'Original colors');
      expect(await store.hasRetirements(), isTrue);
      expect(
        await LocalPackStore(store.root).readInstalled('fixture-pack'),
        isNull,
      );
      await store.install(source);
      expect(await store.readInstalled('fixture-pack'), isNotNull);
      expect(await store.readRetirements(), isEmpty);
    },
  );

  test(
    'authoritative tombstones permanently block cached archives after restart',
    () async {
      final first = await store.install(source);
      await store.applyTombstones(
        [deleted('fixture-pack')],
        expectedRevisions: {'fixture-pack': 1},
        expectedDigests: {'fixture-pack': first.manifest.digest},
      );
      final reopened = LocalPackStore(store.root);
      expect(await reopened.readInstalled('fixture-pack'), isNull);
      expect(await reopened.readAllInstalled(), isEmpty);
      expect(
        (await reopened.readRetirements()).single.tombstone!.sourceOrigin,
        'https://content.example',
      );
      await expectLater(reopened.install(source), throwsStateError);
      await expectLater(
        reopened.install(await fixture('fixture-pack', revision: 3)),
        throwsStateError,
      );
    },
  );

  test(
    'whole-batch CAS validation prevents partial deletion or stale removal',
    () async {
      await store.install(source);
      await store.install(await fixture('other'));
      await expectLater(
        store.applyTombstones(
          [deleted('fixture-pack'), deleted('other')],
          expectedRevisions: {'fixture-pack': 1, 'other': 2},
        ),
        throwsStateError,
      );
      expect((await store.readAllInstalled()).length, 2);
      expect(await store.readRetirements(), isEmpty);
      await expectLater(
        store.removeDownload('fixture-pack', expectedRevision: 2),
        throwsStateError,
      );
      expect(await store.readInstalled('fixture-pack'), isNotNull);
    },
  );

  test(
    'removed public Pack can receive a later valid tombstone using last-known CAS',
    () async {
      await store.install(source);
      await store.removeDownload('fixture-pack', expectedRevision: 1);
      await store.cleanupRetired();
      await store.applyTombstones(
        [deleted('fixture-pack')],
        expectedRevisions: {'fixture-pack': 1},
      );
      expect((await store.readRetirements()).single.isAuthoritative, isTrue);
      await expectLater(store.install(source), throwsStateError);
    },
  );

  test(
    'leases protect snapshot image bytes during removal and bounded cleanup',
    () async {
      final first = await store.install(source);
      final lease = (await store.retainForSession(['fixture-pack']))!;
      final secondLease = (await store.retainForSession(['fixture-pack']))!;
      await store.removeDownload('fixture-pack', expectedRevision: 1);
      expect(await store.cleanupRetired(maxEntries: 1), 0);
      expect(
        await PrivatePackImages.read(
          store.root,
          PrivateImageReference.parse(first.cards.first.imageReference),
        ),
        isNotEmpty,
      );
      await lease.release();
      expect(await store.cleanupRetired(), 0);
      await secondLease.release();
      expect(await store.cleanupRetired(maxEntries: 1), 1);
      expect(await first.directory.exists(), isFalse);
      expect((await store.readRetirements()).single.isAuthoritative, isFalse);
      await store.install(source);
      expect(await store.readInstalled('fixture-pack'), isNotNull);
    },
  );

  test(
    'tombstone retirement retains active snapshot lease until explicit exit',
    () async {
      await store.install(source);
      final lease = (await store.retainForSession(['fixture-pack']))!;
      await store.applyTombstones(
        [deleted('fixture-pack')],
        expectedRevisions: {'fixture-pack': 1},
      );
      expect(await store.retainForSession(['fixture-pack']), isNull);
      expect(await store.cleanupRetired(), 0);
      expect(
        await PrivatePackImages.read(
          store.root,
          PrivateImageReference.parse(
            lease.packs.single.cards.first.imageReference,
          ),
        ),
        isNotEmpty,
      );
      await lease.release();
      expect(await store.cleanupRetired(), 1);
    },
  );

  for (final failure in [false, true]) {
    test(
      '${failure ? 'activation' : 'no-space'} failure preserves all installed Pack pointers',
      () async {
        await store.install(source);
        final broken = LocalPackStore(
          store.root,
          io: _FailRetirement(writeFailure: !failure, activateFailure: failure),
        );
        await expectLater(
          broken.applyTombstones(
            [deleted('fixture-pack')],
            expectedRevisions: {'fixture-pack': 1},
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(await store.readInstalled('fixture-pack'), isNotNull);
        expect(await store.readRetirements(), isEmpty);
        await expectLater(
          broken.removeDownload('fixture-pack', expectedRevision: 1),
          throwsA(isA<FileSystemException>()),
        );
        expect(await store.readInstalled('fixture-pack'), isNotNull);
      },
    );
  }

  test(
    'a removed slot permits a sixth distinct Free Pack while tombstones remain durable',
    () async {
      for (var i = 0; i < 5; i++) {
        await store.install(await fixture('pack-$i'));
      }
      final sixth = await fixture('sixth');
      await expectLater(store.install(sixth), throwsStateError);
      await store.removeDownload('pack-0', expectedRevision: 1);
      await store.install(sixth);
      expect((await store.readAllInstalled()).length, 5);
      await store.applyTombstones(
        [deleted('pack-1')],
        expectedRevisions: {'pack-1': 1},
      );
      await store.install(await fixture('seventh'));
      expect((await store.readAllInstalled()).length, 5);
      await expectLater(
        store.install(await fixture('pack-1', revision: 3)),
        throwsStateError,
      );
    },
  );

  test(
    'tombstones reject normalized invalid timestamps, unsupported reasons and origins',
    () {
      final wire = {
        'packId': 'fixture-pack',
        'revision': 2,
        'deletedAt': '2026-02-30T00:00:00Z',
        'reason': 'administrative_deletion',
      };
      expect(
        () => PackTombstone.fromWire(
          wire,
          sourceOrigin: 'https://content.example',
        ),
        throwsFormatException,
      );
      wire['deletedAt'] = '2026-01-01T24:00:00Z';
      expect(
        () => PackTombstone.fromWire(
          wire,
          sourceOrigin: 'https://content.example',
        ),
        throwsFormatException,
      );
      wire['deletedAt'] = '2026-01-01T00:00:00.123Z';
      final valid = PackTombstone.fromWire(
        wire,
        sourceOrigin: 'https://content.example',
      );
      expect(PackTombstone.fromJson(valid.toJson()).deletedAt, valid.deletedAt);
      expect(
        () =>
            PackTombstone.fromWire(wire, sourceOrigin: 'http://remote.example'),
        throwsFormatException,
      );
    },
  );
  test(
    'foreign process shared generation lease prevents cleanup until process death',
    () async {
      final installed = await store.install(source);
      final child = await Process.start('python3', [
        '-u',
        '-c',
        r"""
import fcntl, os, sys, time
handle = open(os.path.join(sys.argv[1], '.playback.lock'), 'a+b')
fcntl.lockf(handle, fcntl.LOCK_SH)
print('ready', flush=True)
while True: time.sleep(1)
""",
        installed.directory.path,
      ]);
      try {
        expect(
          await child.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 5)),
          'ready',
        );
        await store.removeDownload('fixture-pack', expectedRevision: 1);
        expect(await store.cleanupRetired(), 0);
        expect(
          await PrivatePackImages.read(
            store.root,
            PrivateImageReference.parse(installed.cards.first.imageReference),
          ),
          isNotEmpty,
        );
        child.kill(ProcessSignal.sigkill);
        await child.exitCode;
        expect(await store.cleanupRetired(maxEntries: 1), 1);
      } finally {
        child.kill(ProcessSignal.sigkill);
        await child.exitCode;
      }
    },
    skip: !Platform.isLinux,
  );

  for (final committed in [false, true]) {
    test(
      'SIGKILL ${committed ? 'after' : 'before'} tombstone commit preserves atomic retirement semantics',
      () async {
        final installed = await store.install(source);
        final lease = (await store.retainForSession(['fixture-pack']))!;
        final record = PackRetirement(
          packId: 'fixture-pack',
          name: installed.manifest.pack.name,
          topicId: installed.manifest.pack.topicId,
          installedRevision: 1,
          manifestSha256: installed.manifest.digest,
          removedAt: DateTime.utc(2026, 11, 12),
          publicSyncEligible: true,
          tombstone: deleted('fixture-pack'),
        );
        final payload = jsonEncode({
          'schemaVersion': 1,
          'packs': [record.toJson()],
        });
        final child = await Process.start('python3', [
          '-u',
          '-c',
          r"""
import fcntl, os, sys, time
root = sys.argv[1]
lock = open(os.path.join(root, '.install.lock'), 'a+b')
fcntl.lockf(lock, fcntl.LOCK_EX)
pending = os.path.join(root, 'tombstones.pending')
with open(pending, 'w') as output:
    output.write(sys.argv[2]); output.flush(); os.fsync(output.fileno())
if sys.argv[3] == 'commit': os.replace(pending, os.path.join(root, 'tombstones.json'))
print('ready', flush=True)
while True: time.sleep(1)
""",
          store.root.path,
          payload,
          committed ? 'commit' : 'stage',
        ]);
        try {
          expect(
            await child.stdout
                .transform(utf8.decoder)
                .transform(const LineSplitter())
                .first
                .timeout(const Duration(seconds: 5)),
            'ready',
          );
          expect(
            await store.readInstalled('fixture-pack'),
            committed ? isNull : isNotNull,
          );
          child.kill(ProcessSignal.sigkill);
          await child.exitCode;
          final reopened = LocalPackStore(store.root);
          await reopened.recoverInterruptedDownloads(maxEntries: 1);
          expect(
            await reopened.readInstalled('fixture-pack'),
            committed ? isNull : isNotNull,
          );
          expect(await reopened.cleanupRetired(maxEntries: 1), 0);
          expect(
            await PrivatePackImages.read(
              store.root,
              PrivateImageReference.parse(
                lease.packs.single.cards.first.imageReference,
              ),
            ),
            isNotEmpty,
          );
          await lease.release();
          if (committed) {
            expect(await reopened.cleanupRetired(maxEntries: 1), 1);
            await expectLater(reopened.install(source), throwsStateError);
          }
        } finally {
          child.kill(ProcessSignal.sigkill);
          await child.exitCode;
          await lease.release();
        }
      },
      skip: !Platform.isLinux,
    );
  }

  test(
    'concurrent newer activation defeats a stale removal or tombstone CAS',
    () async {
      await store.install(source);
      final newer = await fixture('fixture-pack', revision: 2);
      await store.install(newer);
      await expectLater(
        store.removeDownload('fixture-pack', expectedRevision: 1),
        throwsStateError,
      );
      await expectLater(
        store.applyTombstones(
          [deleted('fixture-pack', revision: 3)],
          expectedRevisions: {'fixture-pack': 1},
        ),
        throwsStateError,
      );
      expect(
        (await store.readInstalled('fixture-pack'))!.manifest.pack.revision,
        2,
      );
    },
  );

  test(
    'cancellation before local removal commit retains the active Pack',
    () async {
      final installed = await store.install(source);
      var checks = 0;
      await expectLater(
        store.removeDownload(
          'fixture-pack',
          expectedRevision: 1,
          expectedDigest: installed.manifest.digest,
          checkCancelled: () {
            if (++checks == 2) throw StateError('cancelled');
          },
        ),
        throwsStateError,
      );
      expect(checks, 2);
      expect(
        (await store.readInstalled('fixture-pack'))!.manifest.digest,
        installed.manifest.digest,
      );
      expect(await store.readRetirements(), isEmpty);
    },
  );

  test(
    'lease disposal releases descriptors and local holds when its root disappears',
    () async {
      await store.install(source);
      final lease = (await store.retainForSession(['fixture-pack']))!;
      await store.removeDownload('fixture-pack', expectedRevision: 1);
      Future<void> copyDirectory(Directory from, Directory to) async {
        await to.create(recursive: true);
        await for (final entry in from.list(followLinks: false)) {
          final name = entry.path.split(Platform.pathSeparator).last;
          if (entry is Directory) {
            await copyDirectory(entry, Directory('${to.path}/$name'));
          } else if (entry is File) {
            await entry.copy('${to.path}/$name');
          }
        }
      }

      final backup = Directory('${temp.path}/backup');
      await copyDirectory(store.root, backup);
      await store.root.delete(recursive: true);
      await lease.release();
      await lease.release();
      expect(await store.root.exists(), isFalse);
      // Recreating the exact path exposes a leaked static hold: no live session
      // remains, so restored retired bytes must now be reclaimable.
      await copyDirectory(backup, store.root);
      expect(await store.cleanupRetired(), 1);
    },
  );
  test(
    'remove and redownload retain old leased bytes then reclaim only the old generation',
    () async {
      final original = await store.install(source);
      final lease = (await store.retainForSession(['fixture-pack']))!;
      await store.removeDownload('fixture-pack', expectedRevision: 1);
      final downloaded = await store.install(source);
      expect(await store.readRetirements(), isEmpty);
      expect(downloaded.directory.path, isNot(original.directory.path));
      expect(await store.cleanupRetired(), 0);
      expect(
        await PrivatePackImages.read(
          store.root,
          PrivateImageReference.parse(original.cards.first.imageReference),
        ),
        isNotEmpty,
      );
      await lease.release();
      expect(await store.cleanupRetired(maxEntries: 1), 1);
      expect(await original.directory.exists(), isFalse);
      expect(await downloaded.directory.exists(), isTrue);
      expect(
        (await store.readInstalled('fixture-pack'))!.directory.path,
        downloaded.directory.path,
      );
    },
  );

  test(
    'updated Pack reclaims non-current generations only after their read lease ends',
    () async {
      final original = await store.install(source);
      final lease = (await store.retainForSession(['fixture-pack']))!;
      final updated = await store.install(
        await fixture('fixture-pack', revision: 2),
      );
      expect(await store.cleanupRetired(), 0);
      await lease.release();
      expect(await store.cleanupRetired(maxEntries: 1), 1);
      expect(await original.directory.exists(), isFalse);
      expect(
        (await store.readInstalled('fixture-pack'))!.manifest.pack.revision,
        2,
      );
      expect(await updated.directory.exists(), isTrue);
    },
  );

  test(
    'uncertain active pointer or tombstone ledger cannot authorize generation cleanup',
    () async {
      final original = await store.install(source);
      await store.install(await fixture('fixture-pack', revision: 2));
      final active = File('${original.directory.parent.path}/active');
      final saved = await active.readAsBytes();
      await active.writeAsBytes([255]);
      expect(await store.cleanupRetired(), 0);
      expect(await original.directory.exists(), isTrue);
      await active.writeAsBytes(saved);
      await File('${store.root.path}/tombstones.json').writeAsString('{broken');
      await expectLater(store.cleanupRetired(), throwsFormatException);
      expect(await original.directory.exists(), isTrue);
    },
  );
}
