import 'dart:async';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:biguess/data/local/local_pack_file.dart';
import 'dart:io';

import 'package:biguess/data/catalog/catalog_models.dart';
import 'package:biguess/data/download/pack_download_repository.dart';
import 'package:biguess/data/local/local_content_runtime.dart';
import 'package:biguess/data/local/local_pack_store.dart';
import 'package:biguess/data/local/pack_tombstone.dart';
import 'package:biguess/data/local/private_pack_images.dart';
import 'package:biguess/data/updates/pack_update_repository.dart';
import 'package:biguess/domain/models/game_session_configuration.dart';
import 'package:biguess/domain/use_cases/select_packs_use_case.dart';
import 'package:biguess/providers/catalog_controller.dart';
import 'package:biguess/providers/game_session_controller.dart';
import 'package:biguess/providers/gameplay_network_gate.dart';
import 'package:biguess/providers/local_pack_management_providers.dart';
import 'package:biguess/providers/pack_download_controller.dart';
import 'package:biguess/providers/pack_update_controller.dart';
import 'package:biguess/providers/topic_pack_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pack_download_controller_test.dart'
    show ControlledDownload, downloadSummary;
import '../unit/catalog_controller_test.dart' show FakeCatalogRepository;

class HomeDeletionSync implements PackUpdateRepository {
  int checks = 0;
  Completer<void>? hold;
  List<PackUpdateStatus> results = [];
  @override
  Future<List<PackUpdateStatus>> check({
    PackDownloadCancellation? cancellation,
  }) async {
    checks++;
    if (hold != null) await (cancellation?.race(hold!.future) ?? hold!.future);
    cancellation?.throwIfCancelled();
    return results;
  }

  @override
  Future<InstalledLocalPack> update(
    PackUpdateStatus status, {
    void Function(PackDownloadProgress)? onProgress,
    PackDownloadCancellation? cancellation,
  }) => throw StateError('Not an update');
  @override
  void close() {}
}

PackUpdateStatus deletionStatus() => PackUpdateStatus(
  packId: 'fixture-pack',
  installedRevision: 1,
  state: PackUpdateAvailability.deleted,
  revision: 2,
  tombstone: PackTombstone(
    packId: 'fixture-pack',
    revision: 2,
    deletedAt: DateTime.utc(2026, 11, 12),
    sourceOrigin: 'https://catalog.example',
  ),
);

void main() {
  late Directory directory;
  late LocalContentRuntime runtime;
  late HomeDeletionSync remote;
  late ControlledDownload downloads;
  late ProviderContainer container;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('retirement-home-');
    runtime = await LocalContentRuntime.open(
      supportDirectory: directory,
      importFile: File('test/fixtures/local_pack/colors.biguesspack'),
    );
    remote = HomeDeletionSync();
    downloads = ControlledDownload(runtime.store!);
    container = ProviderContainer(
      overrides: [
        localContentRuntimeProvider.overrideWithValue(runtime),
        publicCatalogBaseUriProvider.overrideWithValue(
          Uri.parse('https://catalog.example'),
        ),
        packUpdateRepositoryProvider.overrideWithValue(remote),
        packDownloadRepositoryProvider.overrideWithValue(downloads),
        publicCatalogRepositoryProvider.overrideWithValue(
          FakeCatalogRepository(
            cached: CatalogSnapshot(
              origin: 'https://catalog.example',
              topics: const [
                CatalogTopicSummary(
                  id: 'fixture-topic',
                  name: 'Colors',
                  revision: 1,
                ),
              ],
              packs: const [downloadSummary],
              topicsCheckedAt: DateTime.utc(2026),
              packsCheckedAt: {'fixture-topic': DateTime.utc(2026)},
            ),
          ),
        ),
      ],
    );
    container.read(catalogBrowseProvider);
    await container.pump();
  });
  tearDown(() async {
    container.dispose();
    await runtime.releasePlayback();
    runtime.close();
    await directory.delete(recursive: true);
  });

  test(
    'manual valid Home sync retires and blocks cached redownload through restart',
    () async {
      remote.results = [deletionStatus()];
      expect(container.read(packRetirementsProvider), isEmpty);
      expect(remote.checks, 0);
      await container.read(packUpdatesProvider.notifier).check();
      expect(remote.checks, 1);
      expect(container.read(packUpdatesProvider).error, isNull);
      expect(
        container
            .read(contentRepositoryProvider)
            .getInstalledCardsForPack('fixture-pack'),
        isNull,
      );
      expect(runtime.usesSqlite, isTrue);
      expect(
        container.read(packRetirementsProvider).single.isAuthoritative,
        isTrue,
      );
      await container
          .read(packDownloadsProvider.notifier)
          .download(downloadSummary);
      expect(downloads.calls, 0);
      expect(
        container.read(packDownloadsProvider)['fixture-pack']!.error,
        'deleted',
      );
      await container.pump();
      expect(
        container
            .read(browsePacksProvider('fixture-topic'))
            .single
            .availability,
        PackAvailability.unavailable,
      );
      final reopened = await LocalContentRuntime.open(
        supportDirectory: directory,
      );
      expect(
        reopened.repository.getInstalledCardsForPack('fixture-pack'),
        isNull,
      );
      expect(reopened.retirements.single.isAuthoritative, isTrue);
      expect(reopened.usesSqlite, isTrue);
      await expectLater(
        reopened.store!.install(
          File('test/fixtures/local_pack/colors.biguesspack'),
        ),
        throwsStateError,
      );
      reopened.close();
    },
  );

  test(
    'local removal works offline without endpoint and is reversible',
    () async {
      // An absent online repository must not block a local storage action.
      container.dispose();
      container = ProviderContainer(
        overrides: [localContentRuntimeProvider.overrideWithValue(runtime)],
      );
      final pack = container.read(installedDownloadPacksProvider).single;
      await container.read(packUpdatesProvider.notifier).removeDownload(pack);
      expect(container.read(packUpdatesProvider).error, isNull);
      expect(await runtime.store!.readAllInstalled(), isEmpty);
      expect(
        container.read(packRetirementsProvider).single.isAuthoritative,
        isFalse,
      );
      expect(runtime.repository.getInstalledCardsForPack(pack.id), isNull);
      expect(runtime.usesSqlite, isTrue);
      await runtime.store!.install(
        File('test/fixtures/local_pack/colors.biguesspack'),
      );
      await runtime.reloadInstalled();
      container.invalidate(contentRepositoryProvider);
      expect(container.read(installedDownloadPacksProvider).single.id, pack.id);
      expect(container.read(packRetirementsProvider), isEmpty);
      expect(remote.checks, 0);
    },
  );

  test(
    'active rounds reject synchronization/removal; Home applies deletion without old-image loss midgame',
    () async {
      container.read(playbackLeaseLifecycleProvider);
      final verified = (await runtime.verifyForPlay(
        topicId: 'fixture-topic',
        packIds: ['fixture-pack'],
      ))!;
      final originalReference = verified.installedCards!.first.imageReference;
      final session = container.read(gameSessionProvider.notifier);
      session.configure(
        GameSessionConfiguration(
          topicId: 'fixture-topic',
          packIds: ['fixture-pack'],
          rounds: 2,
        ),
      );
      session.start(
        topic: verified.topic,
        installedPacks: verified.packs,
        installedCards: verified.installedCards!,
      );
      final snapshot = container.read(gameSessionProvider).snapshot;
      remote.results = [deletionStatus()];
      await container.read(packUpdatesProvider.notifier).check();
      await container
          .read(packUpdatesProvider.notifier)
          .removeDownload(verified.pack);
      expect(remote.checks, 0);
      expect(await runtime.store!.readInstalled('fixture-pack'), isNotNull);
      expect(
        await PrivatePackImages.read(
          runtime.store!.root,
          PrivateImageReference.parse(originalReference),
        ),
        isNotEmpty,
      );
      session.nextRound();
      expect(container.read(gameSessionProvider).snapshot, same(snapshot));
      session.returnHome();
      await container.pump();
      await container.read(packUpdatesProvider.notifier).check();
      expect(remote.checks, 1);
      expect(await runtime.store!.readInstalled('fixture-pack'), isNull);
    },
  );

  test(
    'Start cancels pending sync; late deletion is not queued for automatic Home application',
    () async {
      remote.results = [deletionStatus()];
      remote.hold = Completer<void>();
      final checking = container.read(packUpdatesProvider.notifier).check();
      container.read(gameplayPreparingProvider.notifier).state = true;
      await container.read(packUpdatesProvider.notifier).stopForGameplay();
      await checking;
      expect(await runtime.store!.readInstalled('fixture-pack'), isNotNull);
      container.read(gameplayPreparingProvider.notifier).state = false;
      expect(remote.checks, 1);
      expect(container.read(packRetirementsProvider), isEmpty);
      remote.hold = null;
      await container.read(packUpdatesProvider.notifier).check();
      expect(await runtime.store!.readInstalled('fixture-pack'), isNull);
    },
  );

  test(
    'unknown/unavailable or missing evidence never retire installed content',
    () async {
      for (final status in [
        PackUpdateAvailability.unknown,
        PackUpdateAvailability.unavailable,
        PackUpdateAvailability.deleted,
      ]) {
        remote.results = [
          PackUpdateStatus(
            packId: 'fixture-pack',
            installedRevision: 1,
            state: status,
          ),
        ];
        await container.read(packUpdatesProvider.notifier).check();
        expect(await runtime.store!.readInstalled('fixture-pack'), isNotNull);
        expect(container.read(packRetirementsProvider), isEmpty);
      }
      expect(container.read(packUpdatesProvider).error, 'corrupt');
    },
  );

  test(
    'a later Home tombstone retires a previously user-removed public Pack',
    () async {
      await container
          .read(packUpdatesProvider.notifier)
          .removeDownload(
            container.read(installedDownloadPacksProvider).single,
          );
      expect(runtime.retirements.single.isAuthoritative, isFalse);
      remote.results = [deletionStatus()];
      await container.read(packUpdatesProvider.notifier).check();
      expect(container.read(packUpdatesProvider).error, isNull);
      expect(runtime.retirements.single.isAuthoritative, isTrue);
    },
  );
  test(
    'explicit legacy rollback cannot resurrect an authoritatively retired matching ID',
    () async {
      await runtime.store!.removeDownload('fixture-pack', expectedRevision: 1);
      final source = ZipDecoder().decodeBytes(
        await File('test/fixtures/local_pack/colors.biguesspack').readAsBytes(),
      );
      final manifest =
          jsonDecode(utf8.decode(source.find('manifest.json')!.content))
              as Map<String, dynamic>;
      const id = 'legacy:pack:Anime:Attack%20on%20Titan';
      manifest['topic']['id'] = 'legacy:topic:Anime';
      manifest['pack']['id'] = id;
      manifest['pack']['topicId'] = 'legacy:topic:Anime';
      for (final card in manifest['cards'] as List) {
        card['packId'] = id;
      }
      final archive = Archive();
      for (final entry in source.files) {
        final bytes = entry.name == 'manifest.json'
            ? utf8.encode(LocalPackManifest.canonicalJson(manifest))
            : entry.content;
        archive.add(
          ArchiveFile(entry.name, bytes.length, bytes)
            ..compression = CompressionType.none
            ..mode = 0x81a4,
        );
      }
      final file = await File(
        '${directory.path}/legacy-id.biguesspack',
      ).writeAsBytes(ZipEncoder().encodeBytes(archive));
      await runtime.store!.install(file);
      await runtime.store!.applyTombstones(
        [
          PackTombstone(
            packId: id,
            revision: 2,
            deletedAt: DateTime.utc(2026),
            sourceOrigin: 'https://catalog.example',
          ),
        ],
        expectedRevisions: {id: 1},
      );
      final rollback = await LocalContentRuntime.open(
        supportDirectory: directory,
        useLegacy: true,
      );
      expect(rollback.failure, isNull);
      expect(rollback.repository.getInstalledCardsForPack(id), isNull);
      expect(
        rollback.repository
            .getPacksForTopic('legacy:topic:Anime')
            .any((p) => p.id == id),
        isFalse,
      );
      rollback.close();
    },
  );
}
