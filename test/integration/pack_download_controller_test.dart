import 'dart:async';
import 'dart:io';

import 'package:biguess/data/catalog/catalog_models.dart';
import 'package:biguess/data/download/pack_download_repository.dart';
import 'package:biguess/data/local/local_content_runtime.dart';
import 'package:biguess/data/local/local_pack_store.dart';
import 'package:biguess/data/local/local_pack_file.dart';
import 'package:biguess/data/local/private_pack_images.dart';
import 'package:biguess/domain/models/game_session_configuration.dart';
import 'package:biguess/providers/game_session_controller.dart';
import 'package:archive/archive.dart';
import 'dart:convert';
import 'package:biguess/providers/pack_download_controller.dart';
import 'package:biguess/providers/topic_pack_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class ControlledDownload implements PackDownloadRepository {
  ControlledDownload(this.store);
  final LocalPackStore store;
  int calls = 0;
  Completer<void>? hold;
  String? failure;
  File? source;
  int active = 0, maxActive = 0;
  final started = <String>[];
  @override
  Future<InstalledLocalPack> download(
    CatalogPackSummary summary, {
    void Function(PackDownloadProgress)? onProgress,
    PackDownloadCancellation? cancellation,
  }) async {
    calls++;
    started.add(summary.id);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      cancellation?.throwIfCancelled();
      onProgress?.call(
        const PackDownloadProgress(PackDownloadPhase.downloading, 10, 20),
      );
      if (hold != null) {
        if (cancellation != null) {
          await cancellation.race(hold!.future);
        } else {
          await hold!.future;
        }
      }
      cancellation?.throwIfCancelled();
      if (failure != null) throw PackDownloadFailure(failure!);
      return await store.install(
        source ?? File('test/fixtures/local_pack/colors.biguesspack'),
        checkCancelled: cancellation?.throwIfCancelled,
      );
    } finally {
      active--;
    }
  }

  @override
  void close() {}
}

const downloadSummary = CatalogPackSummary(
  id: 'fixture-pack',
  topicId: 'fixture-topic',
  name: 'Original colors',
  revision: 1,
  cardCount: 2,
  manifestSha256:
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
);

void main() {
  late Directory directory;
  late LocalContentRuntime runtime;
  late ControlledDownload repository;
  late ProviderContainer container;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('download-controller-');
    runtime = await LocalContentRuntime.open(supportDirectory: directory);
    repository = ControlledDownload(runtime.store!);
    container = ProviderContainer(
      overrides: [
        localContentRuntimeProvider.overrideWithValue(runtime),
        packDownloadRepositoryProvider.overrideWithValue(repository),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    runtime.close();
    await directory.delete(recursive: true);
  });

  test(
    'idle is inert; explicit completion refreshes installed browsing and survives offline reopen',
    () async {
      final before = container.read(contentRepositoryProvider);
      expect(container.read(packDownloadsProvider), isEmpty);
      expect(repository.calls, 0);
      await container
          .read(packDownloadsProvider.notifier)
          .download(downloadSummary);
      final after = container.read(contentRepositoryProvider);
      expect(after, isNot(same(before)));
      final cards = after.getInstalledCardsForPack('fixture-pack')!;
      expect(cards.length, 2);
      expect(
        cards.every((c) => c.imageReference.startsWith('biguess-pack:')),
        isTrue,
      );
      expect(
        container.read(packDownloadsProvider)['fixture-pack']!.installed,
        isTrue,
      );
      final reopened = await LocalContentRuntime.open(
        supportDirectory: directory,
      );
      expect(
        reopened.repository.getInstalledCardsForPack('fixture-pack'),
        cards,
      );
      reopened.close();
    },
  );

  test(
    'progress serializes actions; error leaves current content and explicit retry succeeds',
    () async {
      final before = container.read(contentRepositoryProvider);
      repository.hold = Completer<void>();
      repository.failure = 'no-space';
      final pending = container
          .read(packDownloadsProvider.notifier)
          .download(downloadSummary);
      expect(
        container
            .read(packDownloadsProvider)['fixture-pack']!
            .progress!
            .receivedBytes,
        10,
      );
      final duplicate = container
          .read(packDownloadsProvider.notifier)
          .download(downloadSummary);
      expect(repository.calls, 1);
      repository.hold!.complete();
      await pending;
      await duplicate;
      expect(container.read(contentRepositoryProvider), same(before));
      expect(
        container.read(packDownloadsProvider)['fixture-pack']!.error,
        'no-space',
      );
      expect(await runtime.store!.readInstalled('fixture-pack'), isNull);
      repository.hold = null;
      repository.failure = null;
      await container
          .read(packDownloadsProvider.notifier)
          .download(downloadSummary);
      expect(repository.calls, 2);
      expect(
        container
            .read(contentRepositoryProvider)
            .getInstalledCardsForPack('fixture-pack'),
        isNotNull,
      );
    },
  );
  CatalogPackSummary other(String id) => CatalogPackSummary(
    id: id,
    topicId: downloadSummary.topicId,
    name: id,
    revision: 1,
    cardCount: 2,
    manifestSha256: downloadSummary.manifestSha256,
  );

  test(
    'bounded queue deduplicates, cancels waiting jobs and runs only one transfer',
    () async {
      final controller = container.read(packDownloadsProvider.notifier);
      repository.hold = Completer<void>();
      repository.failure = 'no-space';
      final first = controller.download(downloadSummary);
      final second = controller.download(other('second'));
      final third = controller.download(other('third'));
      final fourth = controller.download(other('fourth'));
      await controller.download(other('overflow'));
      final duplicate = controller.download(other('second'));
      expect(repository.started, ['fixture-pack']);
      expect(container.read(packDownloadsProvider)['second']!.queued, isTrue);
      expect(
        container.read(packDownloadsProvider)['overflow']!.error,
        'queue-full',
      );
      controller.cancel('third');
      await third;
      expect(
        container.read(packDownloadsProvider)['third']!.error,
        'cancelled',
      );
      repository.hold!.complete();
      await Future.wait([first, second, fourth, duplicate]);
      expect(repository.started, ['fixture-pack', 'second', 'fourth']);
      expect(repository.maxActive, 1);
      expect(await runtime.store!.readAllInstalled(), isEmpty);
    },
  );

  test(
    'active cancellation preserves installed Cards and manual retry works',
    () async {
      await runtime.store!.install(
        File('test/fixtures/local_pack/colors.biguesspack'),
      );
      await runtime.reloadInstalled();
      final before = container
          .read(contentRepositoryProvider)
          .getInstalledCardsForPack('fixture-pack');
      final controller = container.read(packDownloadsProvider.notifier);
      repository.hold = Completer<void>();
      final pending = controller.download(downloadSummary);
      controller.cancel('fixture-pack');
      expect(
        container.read(packDownloadsProvider)['fixture-pack']!.cancelling,
        isTrue,
      );
      repository.hold!.complete();
      await pending;
      expect(
        container.read(packDownloadsProvider)['fixture-pack']!.error,
        'cancelled',
      );
      expect(
        container
            .read(contentRepositoryProvider)
            .getInstalledCardsForPack('fixture-pack'),
        before,
      );
      repository.hold = null;
      await controller.download(downloadSummary);
      expect(
        container.read(packDownloadsProvider)['fixture-pack']!.installed,
        isTrue,
      );
    },
  );

  test(
    'scope disposal cancels active/queued work and a fresh scope stays idle',
    () async {
      final controller = container.read(packDownloadsProvider.notifier);
      repository.hold = Completer<void>();
      final first = controller.download(downloadSummary);
      final second = controller.download(other('queued'));
      container.dispose();
      await Future.wait([first, second]);
      container = ProviderContainer(
        overrides: [
          localContentRuntimeProvider.overrideWithValue(runtime),
          packDownloadRepositoryProvider.overrideWithValue(repository),
        ],
      );
      expect(container.read(packDownloadsProvider), isEmpty);
      expect(repository.started, ['fixture-pack']);
      expect(await runtime.store!.readAllInstalled(), isEmpty);
    },
  );

  test(
    'verified update refreshes browsing while running session and private generation stay frozen',
    () async {
      final original = await runtime.store!.install(
        File('test/fixtures/local_pack/colors.biguesspack'),
      );
      await runtime.reloadInstalled();
      final content = container.read(contentRepositoryProvider);
      final session = container.read(gameSessionProvider.notifier);
      session.configure(
        GameSessionConfiguration(
          topicId: 'fixture-topic',
          packIds: ['fixture-pack'],
          rounds: 2,
        ),
      );
      session.start(
        topic: content.getTopics().single,
        installedPacks: content.getPacksForTopic('fixture-topic'),
        installedCards: content.getInstalledCardsForPack('fixture-pack')!,
      );
      final before = container.read(gameSessionProvider);
      final archive = ZipDecoder().decodeBytes(
        await File('test/fixtures/local_pack/colors.biguesspack').readAsBytes(),
      );
      final manifest =
          jsonDecode(utf8.decode(archive.find('manifest.json')!.content))
              as Map<String, dynamic>;
      manifest['pack']['revision'] = 2;
      manifest['cards'][0]['name'] = 'Updated Red';
      final changed = Archive();
      for (final file in archive.files) {
        final bytes = file.name == 'manifest.json'
            ? utf8.encode(LocalPackManifest.canonicalJson(manifest))
            : file.content;
        changed.add(
          ArchiveFile(file.name, bytes.length, bytes)
            ..compression = CompressionType.none
            ..mode = 0x81a4,
        );
      }
      repository.source = await File(
        '${directory.path}/update.biguesspack',
      ).writeAsBytes(ZipEncoder().encodeBytes(changed));
      repository.hold = Completer<void>();
      final pending = container
          .read(packDownloadsProvider.notifier)
          .download(downloadSummary);
      expect(container.read(gameSessionProvider), same(before));
      expect(content.getInstalledCardsForPack('fixture-pack'), original.cards);
      repository.hold!.complete();
      await pending;
      expect(container.read(gameSessionProvider), same(before));
      expect(
        container
            .read(contentRepositoryProvider)
            .getPacksForTopic('fixture-topic')
            .single
            .revision,
        2,
      );
      expect(
        container
            .read(contentRepositoryProvider)
            .getInstalledCardsForPack('fixture-pack')!
            .first
            .name,
        'Updated Red',
      );
      expect(before.snapshot!.cards.first.name, 'Red');
      expect(
        await PrivatePackImages.read(
          runtime.store!.root,
          PrivateImageReference.parse(original.cards.first.imageReference),
        ),
        isNotEmpty,
      );
      session.nextRound();
      expect(
        container.read(gameSessionProvider).snapshot,
        same(before.snapshot),
      );
    },
  );
}
