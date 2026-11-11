import 'dart:async';
import 'dart:io';

import 'package:biguess/core/theme/app_theme.dart';
import 'package:biguess/data/catalog/catalog_models.dart';
import 'package:biguess/data/catalog/catalog_repository.dart';
import 'package:biguess/data/local/local_content_runtime.dart';
import 'package:biguess/data/local/private_pack_images.dart';
import 'package:biguess/domain/models/game_session.dart';
import 'package:biguess/presentation/images/content_image_loader.dart';
import 'package:biguess/presentation/screens/game/game_configuration_screen.dart';
import 'package:biguess/providers/catalog_controller.dart';
import 'package:biguess/providers/content_image_provider.dart';
import 'package:biguess/providers/gameplay_network_gate.dart';
import 'package:biguess/providers/game_session_controller.dart';
import 'package:biguess/providers/pack_download_controller.dart';
import 'package:biguess/providers/topic_pack_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration/pack_download_controller_test.dart'
    show ControlledDownload, downloadSummary;

class _PendingCatalog implements CatalogRepository {
  int requests = 0;
  bool closed = false;
  final pending = Completer<CatalogSnapshot>();
  @override
  Future<CatalogSnapshot?> readCached() async =>
      CatalogSnapshot.empty('https://catalog.example');
  @override
  Future<CatalogSnapshot> refreshTopics() {
    requests++;
    return pending.future;
  }

  @override
  Future<CatalogSnapshot> refreshPacks(String topicId) => refreshTopics();
  @override
  void close() {
    closed = true;
    if (requests > 0 && !pending.isCompleted) {
      pending.completeError(const CatalogFailure('closed'));
    }
  }
}

void main() {
  for (final corrupt in [false, true]) {
    testWidgets(
      corrupt
          ? 'Start reopens private images and refuses damaged files without starting a session'
          : 'Start cancels earlier content requests and all session content actions stay offline',
      (tester) async {
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('gameplay-start-'),
        ))!;
        final runtime = (await tester.runAsync(
          () => LocalContentRuntime.open(
            supportDirectory: directory,
            importFile: File('test/fixtures/local_pack/colors.biguesspack'),
          ),
        ))!;
        final realCatalog = _PendingCatalog();
        final downloads = ControlledDownload(runtime.store!)
          ..hold = Completer<void>();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              localContentRuntimeProvider.overrideWithValue(runtime),
              contentImageLoaderProvider.overrideWithValue(
                ContentImageLoader(openStore: () async => runtime.store!),
              ),
              packDownloadRepositoryProvider.overrideWithValue(downloads),
              publicCatalogRepositoryProvider.overrideWith((ref) {
                if (ref.watch(gameplayNetworkBlockedProvider)) return null;
                final repo = realCatalog;
                ref.onDispose(repo.close);
                return repo;
              }),
            ],
            child: MaterialApp(
              theme: AppTheme.lightTheme,
              home: const GameConfigurationScreen(
                topicName: 'Colors',
                packName: 'Original colors',
              ),
            ),
          ),
        );
        await tester.pump();
        final container = ProviderScope.containerOf(
          tester.element(find.byType(GameConfigurationScreen)),
        );
        container.read(catalogBrowseProvider);
        await tester.pump();
        Future<void>? refresh, pendingDownload;
        if (corrupt) {
          await tester.runAsync(() async {
            final installed = await runtime.store!.readInstalled(
              'fixture-pack',
            );
            await File(
              '${installed!.directory.path}/${PrivatePackImages.fileName}',
            ).writeAsBytes([0]);
          });
        } else {
          refresh = container
              .read(catalogBrowseProvider.notifier)
              .refreshTopics();
          await tester.pump();
          await tester.runAsync(() async {
            pendingDownload = container
                .read(packDownloadsProvider.notifier)
                .download(downloadSummary);
          });
          expect(realCatalog.requests, 1);
          expect(downloads.calls, 1);
        }
        await tester.runAsync(() async {
          await tester.tap(find.text('Start Game'));
          for (
            var i = 0;
            i < 200 && container.read(gameplayPreparingProvider);
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        if (corrupt) {
          expect(
            container.read(gameSessionProvider).phase,
            GameSessionPhase.home,
          );
          expect(find.textContaining('could not be verified'), findsOneWidget);
          expect(find.text('Back to Packs'), findsOneWidget);
          expect(container.read(gameplayNetworkBlockedProvider), isFalse);
        } else {
          await tester.runAsync(
            () => Future.wait([refresh!, pendingDownload!]),
          );
          expect(
            container.read(gameSessionProvider).phase,
            GameSessionPhase.active,
          );
          expect(
            container
                .read(gameSessionProvider)
                .snapshot!
                .cards
                .every((c) => c.imageReference.startsWith('biguess-pack:')),
            isTrue,
          );
          expect(
            container.read(packDownloadsProvider)['fixture-pack']!.error,
            'cancelled',
          );
          await container.read(catalogBrowseProvider.notifier).refreshTopics();
          await container
              .read(packDownloadsProvider.notifier)
              .download(downloadSummary);
          expect(realCatalog.requests, 1);
          expect(realCatalog.closed, isTrue);
          expect(downloads.calls, 1);
          expect(
            container.read(packDownloadsProvider)['fixture-pack']!.error,
            'gameplay-active',
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          runtime.close();
          await directory.delete(recursive: true);
        });
      },
    );
  }
}
