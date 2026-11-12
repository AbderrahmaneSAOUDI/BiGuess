import 'dart:io';

import 'package:biguess/core/theme/app_theme.dart';
import 'package:biguess/data/local/local_content_runtime.dart';
import 'package:biguess/presentation/screens/packs/installed_packs_screen.dart';
import 'package:biguess/presentation/screens/topics/topics_screen.dart';
import 'package:biguess/providers/catalog_controller.dart';
import 'package:biguess/providers/pack_update_controller.dart';
import 'package:biguess/providers/topic_pack_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration/pack_retirement_controller_test.dart'
    show HomeDeletionSync, deletionStatus;

void main() {
  for (final serverDeletion in [false, true]) {
    testWidgets(
      serverDeletion
          ? 'manual Home check shows publisher deletion and no redownload action'
          : 'offline Remove Download confirms local-only removal and keeps Home management reachable',
      (tester) async {
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('retirement-widget-'),
        ))!;
        final runtime = (await tester.runAsync(
          () => LocalContentRuntime.open(
            supportDirectory: directory,
            importFile: File('test/fixtures/local_pack/colors.biguesspack'),
          ),
        ))!;
        final remote = HomeDeletionSync()..results = [deletionStatus()];
        tester.view.physicalSize = const Size(400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              localContentRuntimeProvider.overrideWithValue(runtime),
              publicCatalogBaseUriProvider.overrideWithValue(
                serverDeletion ? Uri.parse('https://catalog.example') : null,
              ),
              packUpdateRepositoryProvider.overrideWithValue(remote),
              automaticUpdateChecksProvider.overrideWithValue(false),
            ],
            child: MaterialApp(
              theme: AppTheme.lightTheme,
              home: const TopicsScreen(),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(find.text('Manage installed Packs'));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        final container = ProviderScope.containerOf(
          tester.element(find.byType(InstalledPacksScreen)),
        );
        expect(remote.checks, 0);
        expect(
          find.textContaining('Offline devices may keep copies'),
          findsOneWidget,
        );
        if (serverDeletion) {
          await tester.runAsync(() async {
            await tester.tap(find.text('Check for updates'));
            for (
              var i = 0;
              i < 200 && container.read(packUpdatesProvider).busy;
              i++
            ) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
          });
        } else {
          await tester.runAsync(() => tester.tap(find.text('Remove Download')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(
            find.textContaining(
              'This does not delete content from the server.',
            ),
            findsOneWidget,
          );
          await tester.tap(find.text('Keep Download'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(
            runtime.repository.getInstalledCardsForPack('fixture-pack'),
            isNotNull,
          );
          await tester.runAsync(() => tester.tap(find.text('Remove Download')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.runAsync(() async {
            await tester.tap(
              find.widgetWithText(FilledButton, 'Remove Download'),
            );
            for (
              var i = 0;
              i < 200 && container.read(packUpdatesProvider).busy;
              i++
            ) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
          });
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          runtime.repository.getInstalledCardsForPack('fixture-pack'),
          isNull,
        );
        expect(
          find.text(
            serverDeletion ? 'Deleted by publisher' : 'Download removed',
          ),
          findsOneWidget,
        );
        expect(
          find.text('Browse downloads'),
          serverDeletion ? findsNothing : findsOneWidget,
        );
        expect(remote.checks, serverDeletion ? 1 : 0);
        expect(container.read(packUpdatesProvider).error, isNull);
        if (!serverDeletion) {
          await tester.tap(find.text('Browse downloads'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.text('Manage installed Packs'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await runtime.releasePlayback();
          runtime.close();
          await directory.delete(recursive: true);
        });
      },
    );
  }
}
