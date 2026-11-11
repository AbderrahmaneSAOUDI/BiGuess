import 'dart:async';
import 'dart:io';

import 'package:biguess/core/theme/app_theme.dart';
import 'package:biguess/data/local/local_content_runtime.dart';
import 'package:biguess/presentation/screens/packs/installed_packs_screen.dart';
import 'package:biguess/presentation/screens/topics/topics_screen.dart';
import 'package:biguess/providers/pack_update_controller.dart';
import 'package:biguess/providers/topic_pack_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration/pack_update_controller_test.dart'
    show ControlledUpdates, makeUpdatedFixture;

void main() {
  testWidgets(
    'Home management checks only on demand; Update alone activates new revision',
    (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('home-updates-'),
      ))!;
      final runtime = (await tester.runAsync(
        () => LocalContentRuntime.open(
          supportDirectory: directory,
          importFile: File('test/fixtures/local_pack/colors.biguesspack'),
        ),
      ))!;
      final source = (await tester.runAsync(
        () => makeUpdatedFixture(directory),
      ))!;
      final repository = ControlledUpdates(runtime.store!, source);
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localContentRuntimeProvider.overrideWithValue(runtime),
            packUpdateRepositoryProvider.overrideWithValue(repository),
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
      expect(repository.checks, 0);
      await tester.tap(find.text('Manage installed Packs'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(InstalledPacksScreen), findsOneWidget);
      expect(find.text('Not checked'), findsOneWidget);
      expect(repository.checks, 0);
      await tester.tap(find.text('Check for updates'));
      await tester.pump();
      expect(repository.checks, 1);
      expect(repository.updates, 0);
      expect(find.text('Update available'), findsOneWidget);
      expect(find.text('Installed · revision 1'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(InstalledPacksScreen)),
      );
      container.invalidate(installedDownloadPacksProvider);
      await tester.pump();
      expect(repository.checks, 1);
      repository.hold = Completer<void>();
      await tester.runAsync(() async {
        await tester.tap(find.text('Update'));
      });
      await tester.pump();
      expect(find.textContaining('5 / 10 bytes'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      await tester.runAsync(() async {
        repository.hold!.complete();
        for (
          var i = 0;
          i < 200 && container.read(packUpdatesProvider).busy;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();
      expect(repository.updates, 1);
      expect(find.text('Up to date'), findsOneWidget);
      expect(find.text('Installed · revision 2'), findsOneWidget);
      expect(repository.checks, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        runtime.close();
        await directory.delete(recursive: true);
      });
    },
  );
}
