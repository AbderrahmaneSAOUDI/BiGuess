import 'dart:async';
import 'dart:io';

import 'package:biguess/data/catalog/catalog_models.dart';
import 'package:biguess/data/download/pack_download_repository.dart';
import 'package:biguess/data/local/local_content_runtime.dart';
import 'package:biguess/data/local/local_pack_store.dart';
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
  @override
  Future<InstalledLocalPack> download(
    CatalogPackSummary summary, {
    void Function(PackDownloadProgress)? onProgress,
  }) async {
    calls++;
    onProgress?.call(
      const PackDownloadProgress(PackDownloadPhase.downloading, 10, 20),
    );
    if (hold != null) await hold!.future;
    if (failure != null) throw PackDownloadFailure(failure!);
    return store.install(File('test/fixtures/local_pack/colors.biguesspack'));
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
      await container
          .read(packDownloadsProvider.notifier)
          .download(downloadSummary);
      expect(repository.calls, 1);
      repository.hold!.complete();
      await pending;
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
}
