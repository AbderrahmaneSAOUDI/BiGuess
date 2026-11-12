import 'dart:io';

import 'package:biguess/core/theme/app_theme.dart';
import 'package:biguess/data/local/local_content_runtime.dart';
import 'package:biguess/data/local/pack_tombstone.dart';
import 'package:biguess/data/local/private_pack_images.dart';
import 'package:biguess/domain/models/game_session.dart';
import 'package:biguess/presentation/images/content_image_loader.dart';
import 'package:biguess/presentation/screens/game/game_screen.dart';
import 'package:biguess/presentation/screens/topics/topics_screen.dart';
import 'package:biguess/providers/content_image_provider.dart';
import 'package:biguess/providers/game_session_controller.dart';
import 'package:biguess/providers/gameplay_network_gate.dart';
import 'package:biguess/providers/topic_pack_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'session generation survives setup replacement and retires only after Home',
    (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('leased-game-route-'),
      ))!;
      final runtime = (await tester.runAsync(
        () => LocalContentRuntime.open(
          supportDirectory: directory,
          importFile: File('test/fixtures/local_pack/colors.biguesspack'),
        ),
      ))!;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localContentRuntimeProvider.overrideWithValue(runtime),
            contentImageLoaderProvider.overrideWithValue(
              ContentImageLoader(openStore: () async => runtime.store!),
            ),
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
      final container = ProviderScope.containerOf(
        tester.element(find.byType(TopicsScreen)),
      );
      await tester.ensureVisible(find.text('Colors'));
      await tester.tap(find.text('Colors'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Original colors'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
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
      expect(
        container.read(gameSessionProvider).phase,
        GameSessionPhase.active,
      );
      final snapshot = container.read(gameSessionProvider).snapshot!;
      final reference = snapshot.cards.first.imageReference;
      // Simulate another process's valid Home synchronization. Its retirement
      // must not destroy the already retained generation used by this game.
      await tester.runAsync(() async {
        await runtime.store!.applyTombstones(
          [
            PackTombstone(
              packId: 'fixture-pack',
              revision: 2,
              deletedAt: DateTime.utc(2026, 11, 12),
              sourceOrigin: 'https://catalog.example',
            ),
          ],
          expectedRevisions: {'fixture-pack': 1},
        );
        expect(await runtime.store!.cleanupRetired(), 0);
        expect(
          await PrivatePackImages.read(
            runtime.store!.root,
            PrivateImageReference.parse(reference),
          ),
          isNotEmpty,
        );
      });
      container.read(gameSessionProvider.notifier).nextRound();
      expect(container.read(gameSessionProvider).snapshot, same(snapshot));
      await tester.runAsync(() async {
        container.read(gameSessionProvider.notifier).returnHome();
        Navigator.of(tester.element(find.byType(GameScreen))).pop();
        for (
          var i = 0;
          i < 100 &&
              container.read(gameSessionProvider).phase !=
                  GameSessionPhase.home;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await runtime.releasePlayback();
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(container.read(gameSessionProvider).phase, GameSessionPhase.home);
      await tester.runAsync(() async {
        expect(await runtime.store!.cleanupRetired(), 1);
      });
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
