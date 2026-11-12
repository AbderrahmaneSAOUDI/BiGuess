import 'dart:io';

import 'package:biguess/data/local/local_content_runtime.dart';
import 'package:biguess/data/local/private_pack_images.dart';
import 'package:biguess/data/repositories/sqlite_content_repository.dart';
import 'package:biguess/domain/models/card.dart';
import 'package:biguess/domain/models/difficulty.dart';
import 'package:biguess/domain/models/pack.dart';
import 'package:biguess/providers/gameplay_network_gate.dart';
import 'package:biguess/providers/game_session_controller.dart';
import 'package:biguess/domain/models/game_session_configuration.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late LocalContentRuntime runtime;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('verified-gameplay-');
    runtime = await LocalContentRuntime.open(
      supportDirectory: directory,
      importFile: File('test/fixtures/local_pack/colors.biguesspack'),
    );
  });
  tearDown(() async {
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
    'Start content comes from verified private files even if SQL projection was replaced',
    () async {
      final sql = runtime.repository as SqliteContentRepository;
      sql.putContent(
        packs: [
          Pack(
            id: 'fixture-pack',
            topicId: 'fixture-topic',
            name: 'Untrusted cache',
            revision: 2,
          ),
        ],
        cards: [
          Card(
            id: 'cache-only',
            packId: 'fixture-pack',
            name: 'Wrong Card',
            imageReference: 'https://invalid.example/card.png',
            difficulty: Difficulty.easy,
          ),
        ],
      );
      sql.setInstalledPack(
        InstalledPackState(
          packId: 'fixture-pack',
          revision: 2,
          installedAt: DateTime.utc(2026),
        ),
      );
      final verified = await runtime.verifyForPlay(
        topicId: 'fixture-topic',
        packIds: ['fixture-pack'],
      );
      expect(verified!.pack.revision, 1);
      expect(verified.installedCards!.map((c) => c.name), ['Red', 'Blue']);
      expect(
        verified.installedCards!.every(
          (c) => c.imageReference.startsWith('biguess-pack:'),
        ),
        isTrue,
      );
      expect(
        await runtime.verifyForPlay(
          topicId: 'other-topic',
          packIds: ['fixture-pack'],
        ),
        isNull,
      );
      expect(
        await runtime.verifyForPlay(
          topicId: 'fixture-topic',
          packIds: ['missing'],
        ),
        isNull,
      );
    },
  );

  test(
    'missing or corrupt private bytes fail before a snapshot can be frozen',
    () async {
      final installed = await runtime.store!.readInstalled('fixture-pack');
      final payload = File(
        '${installed!.directory.path}/${PrivatePackImages.fileName}',
      );
      await payload.writeAsBytes([0]);
      await expectLater(
        runtime.verifyForPlay(
          topicId: 'fixture-topic',
          packIds: ['fixture-pack'],
        ),
        throwsFormatException,
      );
      expect(
        runtime.repository.getInstalledCardsForPack('fixture-pack'),
        isNotEmpty,
      );
    },
  );

  test(
    'gate covers preparation, all rounds and completion, then reopens at Home',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(gameplayNetworkBlockedProvider), isFalse);
      container.read(gameplayPreparingProvider.notifier).state = true;
      expect(container.read(gameplayNetworkBlockedProvider), isTrue);
      final content = (await runtime.verifyForPlay(
        topicId: 'fixture-topic',
        packIds: ['fixture-pack'],
      ))!;
      final session = container.read(gameSessionProvider.notifier);
      session.configure(
        GameSessionConfiguration(
          topicId: 'fixture-topic',
          packIds: ['fixture-pack'],
          rounds: 2,
        ),
      );
      session.start(
        topic: content.topic,
        installedPacks: content.packs,
        installedCards: content.installedCards!,
      );
      container.read(gameplayPreparingProvider.notifier).state = false;
      expect(container.read(gameplayNetworkBlockedProvider), isTrue);
      session.nextRound();
      expect(container.read(gameplayNetworkBlockedProvider), isTrue);
      session.nextRound();
      expect(container.read(gameplayNetworkBlockedProvider), isTrue);
      session.returnHome();
      expect(container.read(gameplayNetworkBlockedProvider), isFalse);
    },
  );
}
