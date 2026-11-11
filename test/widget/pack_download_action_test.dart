import 'dart:async';
import 'dart:io';

import 'package:biguess/core/theme/app_theme.dart';
import 'package:biguess/data/catalog/catalog_models.dart';
import 'package:biguess/data/local/local_content_runtime.dart';
import 'package:biguess/presentation/screens/packs/packs_screen.dart';
import 'package:biguess/providers/catalog_controller.dart';
import 'package:biguess/providers/pack_download_controller.dart';
import 'package:biguess/providers/topic_pack_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration/pack_download_controller_test.dart'
    show ControlledDownload, downloadSummary;
import '../unit/catalog_controller_test.dart' show FakeCatalogRepository;

void main() {
  testWidgets(
    'explicit Download shows progress, storage error and manual retry; success enables local Pack',
    (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('download-widget-'),
      ))!;
      final runtime = (await tester.runAsync(
        () => LocalContentRuntime.open(supportDirectory: directory),
      ))!;
      final repository = ControlledDownload(runtime.store!)
        ..failure = 'no-space'
        ..hold = Completer<void>();
      final catalog = FakeCatalogRepository(
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
      );
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localContentRuntimeProvider.overrideWithValue(runtime),
            packDownloadRepositoryProvider.overrideWithValue(repository),
            publicCatalogRepositoryProvider.overrideWithValue(catalog),
            automaticUpdateChecksProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            home: const PacksScreen(
              topicName: 'Colors',
              topicId: 'fixture-topic',
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(repository.calls, 0);
      expect(find.text('Not downloaded'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('download-fixture-pack')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(repository.calls, 1);
      expect(find.textContaining('10 / 20 bytes'), findsOneWidget);
      repository.hold!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('Not enough private storage'), findsOneWidget);
      expect(find.text('Retry download'), findsOneWidget);
      expect(
        runtime.repository.getInstalledCardsForPack('fixture-pack'),
        isNull,
      );
      repository.failure = null;
      repository.hold = null;
      // Real private-file install and SQLite projection run outside fake time.
      await tester.runAsync(() async {
        await tester.tap(find.text('Retry download'));
        for (var i = 0; i < 100 && !runtime.usesSqlite; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.text('Installed. This Pack is ready to play offline.'),
        findsOneWidget,
      );
      expect(
        runtime.repository.getInstalledCardsForPack('fixture-pack')!.length,
        2,
      );
      expect(find.text('Installed · 2 items'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      runtime.close();
      await tester.runAsync(() => directory.delete(recursive: true));
    },
  );
}
