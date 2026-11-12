import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:biguess/data/download/pack_download_repository.dart';
import 'package:biguess/data/local/local_content_runtime.dart';
import 'package:biguess/data/local/local_pack_file.dart';
import 'package:biguess/data/local/local_pack_store.dart';
import 'package:biguess/data/updates/pack_update_repository.dart';
import 'package:biguess/providers/content_transfer_gate.dart';
import 'package:biguess/providers/gameplay_network_gate.dart';
import 'package:biguess/providers/pack_download_controller.dart';
import 'package:biguess/providers/pack_update_controller.dart';
import 'package:biguess/providers/topic_pack_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pack_download_controller_test.dart'
    show ControlledDownload, downloadSummary;

class ControlledUpdates implements PackUpdateRepository {
  ControlledUpdates(this.store, this.source);
  final LocalPackStore store;
  final File source;
  int checks = 0, updates = 0;
  Completer<void>? hold;
  String? failure;
  static const available = PackUpdateStatus(
    packId: 'fixture-pack',
    installedRevision: 1,
    state: PackUpdateAvailability.updateAvailable,
    revision: 2,
    manifestSha256:
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  );
  Future<void> wait(PackDownloadCancellation? cancellation) async {
    if (hold != null) await (cancellation?.race(hold!.future) ?? hold!.future);
    cancellation?.throwIfCancelled();
    if (failure != null) throw PackDownloadFailure(failure!);
  }

  @override
  Future<List<PackUpdateStatus>> check({
    PackDownloadCancellation? cancellation,
  }) async {
    checks++;
    await wait(cancellation);
    return const [available];
  }

  @override
  Future<InstalledLocalPack> update(
    PackUpdateStatus status, {
    void Function(PackDownloadProgress)? onProgress,
    PackDownloadCancellation? cancellation,
  }) async {
    updates++;
    onProgress?.call(
      const PackDownloadProgress(PackDownloadPhase.downloading, 5, 10),
    );
    await wait(cancellation);
    return store.install(
      source,
      checkCancelled: cancellation?.throwIfCancelled,
    );
  }

  @override
  void close() {}
}

Future<File> makeUpdatedFixture(Directory directory) async {
  final archive = ZipDecoder().decodeBytes(
    await File('test/fixtures/local_pack/colors.biguesspack').readAsBytes(),
  );
  final manifest =
      jsonDecode(utf8.decode(archive.find('manifest.json')!.content))
          as Map<String, dynamic>;
  manifest['pack']['revision'] = 2;
  manifest['cards'][0]['name'] = 'Updated Red';
  final updated = Archive();
  for (final file in archive.files) {
    final bytes = file.name == 'manifest.json'
        ? utf8.encode(LocalPackManifest.canonicalJson(manifest))
        : file.content;
    updated.add(
      ArchiveFile(file.name, bytes.length, bytes)
        ..compression = CompressionType.none
        ..mode = 0x81a4,
    );
  }
  return File(
    '${directory.path}/update.biguesspack',
  ).writeAsBytes(ZipEncoder().encodeBytes(updated));
}

void main() {
  late Directory directory;
  late LocalContentRuntime runtime;
  late ControlledUpdates updates;
  late ControlledDownload downloads;
  late ProviderContainer container;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('update-controller-');
    runtime = await LocalContentRuntime.open(
      supportDirectory: directory,
      importFile: File('test/fixtures/local_pack/colors.biguesspack'),
    );
    updates = ControlledUpdates(
      runtime.store!,
      await makeUpdatedFixture(directory),
    );
    downloads = ControlledDownload(runtime.store!);
    container = ProviderContainer(
      overrides: [
        localContentRuntimeProvider.overrideWithValue(runtime),
        packUpdateRepositoryProvider.overrideWithValue(updates),
        packDownloadRepositoryProvider.overrideWithValue(downloads),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await runtime.releasePlayback();
    await runtime.close();
    if (await directory.exists()) {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }
    }
  });

  test(
    'build/navigation are inert; manual check preserves old revision until Update',
    () async {
      expect(container.read(packUpdatesProvider).statuses, isEmpty);
      expect(container.read(installedDownloadPacksProvider).single.revision, 1);
      container.invalidate(installedDownloadPacksProvider);
      container.read(installedDownloadPacksProvider);
      expect(updates.checks, 0);
      final controller = container.read(packUpdatesProvider.notifier);
      await controller.check();
      expect(updates.checks, 1);
      expect(updates.updates, 0);
      expect(
        (await runtime.store!.readInstalled(
          'fixture-pack',
        ))!.manifest.pack.revision,
        1,
      );
      expect(
        container.read(packUpdatesProvider).statuses['fixture-pack']!.state,
        PackUpdateAvailability.updateAvailable,
      );
      await controller.update('fixture-pack');
      expect(updates.updates, 1);
      expect(container.read(installedDownloadPacksProvider).single.revision, 2);
      expect(
        container.read(packUpdatesProvider).statuses['fixture-pack']!.state,
        PackUpdateAvailability.upToDate,
      );
      expect(
        container
            .read(contentRepositoryProvider)
            .getInstalledCardsForPack('fixture-pack')!
            .first
            .name,
        'Updated Red',
      );
    },
  );

  test(
    'failed checks preserve prior manual status and verified installed content',
    () async {
      final controller = container.read(packUpdatesProvider.notifier);
      await controller.check();
      final checked = container.read(packUpdatesProvider).checkedAt;
      updates.failure = 'offline';
      await controller.check();
      expect(container.read(packUpdatesProvider).checkedAt, checked);
      expect(
        container.read(packUpdatesProvider).statuses['fixture-pack']!.state,
        PackUpdateAvailability.updateAvailable,
      );
      expect(container.read(packUpdatesProvider).error, 'offline');
      expect(
        (await runtime.store!.readInstalled(
          'fixture-pack',
        ))!.manifest.pack.revision,
        1,
      );
    },
  );

  test(
    'initial downloads and update requests share a single transfer lease',
    () async {
      downloads.hold = Completer<void>();
      final downloading = container
          .read(packDownloadsProvider.notifier)
          .download(downloadSummary);
      await container.read(packUpdatesProvider.notifier).check();
      expect(updates.checks, 0);
      expect(container.read(packUpdatesProvider).error, 'transfer-busy');
      await container.read(packDownloadsProvider.notifier).stopForGameplay();
      await downloading;
      updates.hold = Completer<void>();
      final checking = container.read(packUpdatesProvider.notifier).check();
      expect(updates.checks, 1);
      await container
          .read(packDownloadsProvider.notifier)
          .download(downloadSummary);
      expect(downloads.calls, 1);
      expect(
        container.read(packDownloadsProvider)['fixture-pack']!.error,
        'transfer-busy',
      );
      container.read(packUpdatesProvider.notifier).cancel();
      await checking;
      expect(container.read(contentTransferOwnerProvider), isNull);
    },
  );

  test(
    'Start cancellation drains update work; gameplay blocks requests; returning Home is inert',
    () async {
      final controller = container.read(packUpdatesProvider.notifier);
      await controller.check();
      updates.hold = Completer<void>();
      final updating = controller.update('fixture-pack');
      container.read(gameplayPreparingProvider.notifier).state = true;
      await controller.stopForGameplay();
      await updating;
      expect(container.read(packUpdatesProvider).error, 'cancelled');
      await controller.check();
      expect(updates.checks, 1);
      expect(updates.updates, 1);
      expect(container.read(packUpdatesProvider).error, 'gameplay-active');
      expect(
        (await runtime.store!.readInstalled(
          'fixture-pack',
        ))!.manifest.pack.revision,
        1,
      );
      container.read(gameplayPreparingProvider.notifier).state = false;
      expect(updates.checks, 1);
      updates.hold = null;
      await controller.check();
      expect(updates.checks, 2);
    },
  );

  test(
    'a request started when a transfer ends retains its own cancellation handle',
    () async {
      final controller = container.read(packUpdatesProvider.notifier);
      Future<void>? second;
      var restarted = false;
      final subscription = container.listen(contentTransferOwnerProvider, (
        previous,
        next,
      ) {
        if (previous != null && next == null && !restarted) {
          restarted = true;
          updates.hold = Completer<void>();
          second = controller.check();
        }
      });
      await controller.check();
      expect(updates.checks, 2);
      expect(container.read(packUpdatesProvider).busy, isTrue);
      await controller.stopForGameplay().timeout(const Duration(seconds: 2));
      await second!.timeout(const Duration(seconds: 2));
      expect(container.read(packUpdatesProvider).error, 'cancelled');
      expect(container.read(contentTransferOwnerProvider), isNull);
      subscription.close();
    },
  );
}
