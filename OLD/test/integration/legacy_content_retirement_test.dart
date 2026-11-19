import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:biguess/data/local/local_content_runtime.dart';
import 'package:biguess/data/repositories/legacy_manifest_content_repository.dart';
import 'package:biguess/data/repositories/sqlite_content_repository.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('legacy-retirement-');
  });

  tearDown(() async {
    for (var i = 0; i < 5; i++) {
      try {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
        break;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  group('T47 - Legacy Hardcoded Content Retirement', () {
    test(
      'production launch (useLegacy=false) opens SQLite with empty state when no packs are installed',
      () async {
        final runtime = await LocalContentRuntime.open(
          supportDirectory: directory,
          useLegacy: false,
        );

        expect(runtime.usesSqlite, isTrue);
        expect(runtime.repository, isA<SqliteContentRepository>());
        expect(runtime.repository.getTopics(), isEmpty);
        expect(runtime.failure, isNull);

        await runtime.close();
      },
    );

    test(
      'explicit rollback switch (useLegacy=true) enables legacy bundled manifest',
      () async {
        final rollback = await LocalContentRuntime.open(
          supportDirectory: directory,
          useLegacy: true,
        );

        expect(rollback.usesSqlite, isFalse);
        expect(rollback.repository, isA<LegacyManifestContentRepository>());
        final topics = rollback.repository.getTopics();
        expect(topics, isNotEmpty);
        expect(topics.map((t) => t.name), containsAll(['Anime', 'Geography']));

        await rollback.close();
      },
    );

    test(
      'production runtime plays downloaded rights-cleared Pack without legacy dependency',
      () async {
        final fixture = File('test/fixtures/local_pack/colors.biguesspack');
        expect(fixture.existsSync(), isTrue);

        final runtime = await LocalContentRuntime.open(
          supportDirectory: directory,
          importFile: fixture,
          useLegacy: false,
        );

        expect(runtime.usesSqlite, isTrue);
        final topics = runtime.repository.getTopics();
        expect(topics.map((t) => t.name), contains('Colors'));
        expect(topics.map((t) => t.name), isNot(contains('Anime')));

        final packs = runtime.repository.getPacksForTopic(topics.first.id);
        expect(packs, isNotEmpty);
        final cards = runtime.repository.getCardsForPack(packs.first.id);
        expect(cards, isNotEmpty);

        // Cards use local generation paths, not bundled assets
        for (final card in cards) {
          expect(card.imageReference, isNot(startsWith('assets/images/Anime')));
          expect(card.imageReference, isNot(startsWith('assets/images/Geography')));
        }

        await runtime.close();
      },
    );
  });
}
