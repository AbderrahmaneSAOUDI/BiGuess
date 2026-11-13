import 'package:biguess_studio/data/card_summary.dart';
import 'package:biguess_studio/data/dataset_search.dart';
import 'package:biguess_studio/data/pack_summary.dart';
import 'package:biguess_studio/data/studio_dataset.dart';
import 'package:biguess_studio/data/topic_taxonomy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DatasetSearchIndex', () {
    test(
      'indexes and searches by card name, card id, pack name, topic name',
      () {
        final topics = [
          const TopicTaxonomy(
            id: 'topic-anime',
            name: 'Anime Legends',
            state: 'active',
            revision: 1,
          ),
        ];
        final packs = [
          const PackSummary(
            id: 'pack-op',
            topicId: 'topic-anime',
            name: 'One Piece',
            state: 'active',
            revision: 1,
            eligibleCardCount: 2,
            createdByUid: 'col-1',
          ),
        ];
        final cards = [
          const CardSummary(
            id: 'card-luffy',
            packId: 'pack-op',
            name: 'Monkey D. Luffy',
            difficulty: 1,
            state: 'active',
            revision: 2,
            imageReference: 'cards/luffy.webp',
          ),
          const CardSummary(
            id: 'card-zoro',
            packId: 'pack-op',
            name: 'Roronoa Zoro',
            difficulty: 2,
            state: 'active',
            revision: 1,
            imageReference: 'cards/zoro.webp',
          ),
        ];

        final index = DatasetSearchIndex.fromComponents(
          scope: const DatasetScope('proj', 'col-1', 'collector'),
          cards: cards,
          packs: packs,
          topics: topics,
        );

        // Search by Card Name
        final matchLuffy = index.search(const CardSearchQuery(text: 'luffy'));
        expect(matchLuffy.totalMatches, 1);
        expect(matchLuffy.items.first.card.name, 'Monkey D. Luffy');

        // Search by Card ID
        final matchId = index.search(const CardSearchQuery(text: 'card-zoro'));
        expect(matchId.totalMatches, 1);
        expect(matchId.items.first.card.name, 'Roronoa Zoro');

        // Search by Pack Name
        final matchPack = index.search(
          const CardSearchQuery(text: 'One Piece'),
        );
        expect(matchPack.totalMatches, 2);

        // Search by Topic Name
        final matchTopic = index.search(const CardSearchQuery(text: 'Anime'));
        expect(matchTopic.totalMatches, 2);
      },
    );

    test('detects identical byte duplicates separately from similar names', () {
      final topics = [
        const TopicTaxonomy(
          id: 'topic-1',
          name: 'Topic 1',
          state: 'active',
          revision: 1,
        ),
      ];
      final packs = [
        const PackSummary(
          id: 'pack-1',
          topicId: 'topic-1',
          name: 'Pack 1',
          state: 'active',
          revision: 1,
          eligibleCardCount: 6,
          createdByUid: 'col-1',
        ),
      ];
      final cards = [
        // Identical bytes with card-2 (objects/<64-char-hash>.png)
        const CardSummary(
          id: 'card-1',
          packId: 'pack-1',
          name: 'Luffy',
          difficulty: 1,
          state: 'active',
          revision: 1,
          imageReference: 'objects/1111111111111111111111111111111111111111111111111111111111111111.png',
        ),
        const CardSummary(
          id: 'card-2',
          packId: 'pack-1',
          name: 'Strawhat Captain',
          difficulty: 1,
          state: 'active',
          revision: 1,
          imageReference: 'objects/1111111111111111111111111111111111111111111111111111111111111111.png',
        ),
        // Exact name duplicate with card-4
        const CardSummary(
          id: 'card-3',
          packId: 'pack-1',
          name: 'Zoro',
          difficulty: 2,
          state: 'active',
          revision: 1,
          imageReference: 'objects/2222222222222222222222222222222222222222222222222222222222222222.png',
        ),
        const CardSummary(
          id: 'card-4',
          packId: 'pack-1',
          name: 'Zoro',
          difficulty: 2,
          state: 'active',
          revision: 1,
          imageReference: 'objects/3333333333333333333333333333333333333333333333333333333333333333.png',
        ),
        // Similar name (Levenshtein distance <= 2)
        const CardSummary(
          id: 'card-5',
          packId: 'pack-1',
          name: 'Zoroo',
          difficulty: 2,
          state: 'active',
          revision: 1,
          imageReference: 'objects/4444444444444444444444444444444444444444444444444444444444444444.png',
        ),
        // Incomplete image (null imageReference)
        const CardSummary(
          id: 'card-6',
          packId: 'pack-1',
          name: 'Nami (No Image)',
          difficulty: 1,
          state: 'active',
          revision: 1,
          imageReference: null,
        ),
      ];

      final index = DatasetSearchIndex.fromComponents(
        scope: const DatasetScope('proj', 'col-1', 'collector'),
        cards: cards,
        packs: packs,
        topics: topics,
      );

      // Verify summary counts
      expect(index.summaryCounts.totalCards, 6);
      expect(index.summaryCounts.byteDuplicatesCount, 2);
      expect(index.summaryCounts.nameDuplicatesCount, 2);
      expect(index.summaryCounts.similarNamesCount, 3); // Zoro (2) + Zoroo (1)
      expect(index.summaryCounts.incompleteImagesCount, 1);

      // Filter by byte duplicates
      final byteDups = index.search(
        const CardSearchQuery(duplicateFilter: DuplicateFilter.byteDuplicate),
      );
      expect(byteDups.totalMatches, 2);
      expect(byteDups.items.map((m) => m.card.id).toSet(), {
        'card-1',
        'card-2',
      });
      expect(byteDups.items.first.isByteDuplicate, isTrue);
      expect(byteDups.items.first.isNameDuplicate, isFalse);

      // Filter by exact name duplicates
      final nameDups = index.search(
        const CardSearchQuery(duplicateFilter: DuplicateFilter.nameDuplicate),
      );
      expect(nameDups.totalMatches, 2);
      expect(nameDups.items.map((m) => m.card.id).toSet(), {
        'card-3',
        'card-4',
      });
      expect(nameDups.items.first.isNameDuplicate, isTrue);

      // Filter by similar names
      final similar = index.search(
        const CardSearchQuery(duplicateFilter: DuplicateFilter.similarName),
      );
      expect(similar.totalMatches, 3);
      expect(similar.items.map((m) => m.card.id).toSet(), {
        'card-3',
        'card-4',
        'card-5',
      });

      // Filter by incomplete image
      final incomplete = index.search(
        const CardSearchQuery(incompleteImageOnly: true),
      );
      expect(incomplete.totalMatches, 1);
      expect(incomplete.items.first.card.id, 'card-6');
      expect(incomplete.items.first.isIncompleteImage, isTrue);
    });

    test('filters by difficulty, state, and pack', () {
      final topics = [
        const TopicTaxonomy(
          id: 'topic-1',
          name: 'Topic 1',
          state: 'active',
          revision: 1,
        ),
      ];
      final packs = [
        const PackSummary(
          id: 'pack-a',
          topicId: 'topic-1',
          name: 'Pack A',
          state: 'active',
          revision: 1,
          eligibleCardCount: 2,
          createdByUid: 'col-1',
        ),
        const PackSummary(
          id: 'pack-b',
          topicId: 'topic-1',
          name: 'Pack B',
          state: 'active',
          revision: 1,
          eligibleCardCount: 2,
          createdByUid: 'col-1',
        ),
      ];
      final cards = [
        const CardSummary(
          id: 'c1',
          packId: 'pack-a',
          name: 'Alpha',
          difficulty: 1,
          state: 'active',
          revision: 1,
          imageReference: 'alpha.webp',
        ),
        const CardSummary(
          id: 'c2',
          packId: 'pack-a',
          name: 'Beta',
          difficulty: 2,
          state: 'hidden',
          revision: 2,
          imageReference: 'beta.webp',
        ),
        const CardSummary(
          id: 'c3',
          packId: 'pack-b',
          name: 'Gamma',
          difficulty: 1,
          state: 'active',
          revision: 1,
          imageReference: 'gamma.webp',
        ),
        const CardSummary(
          id: 'c4',
          packId: 'pack-b',
          name: 'Delta',
          difficulty: 3,
          state: 'deleted',
          revision: 1,
          imageReference: 'delta.webp',
        ),
      ];

      final index = DatasetSearchIndex.fromComponents(
        scope: const DatasetScope('proj', 'col-1', 'collector'),
        cards: cards,
        packs: packs,
        topics: topics,
      );

      // Pack filter
      final packA = index.search(const CardSearchQuery(packId: 'pack-a'));
      expect(packA.totalMatches, 2);
      expect(packA.items.map((m) => m.card.id).toSet(), {'c1', 'c2'});

      // Difficulty filter
      final diff1 = index.search(const CardSearchQuery(difficulty: 1));
      expect(diff1.totalMatches, 2);
      expect(diff1.items.map((m) => m.card.id).toSet(), {'c1', 'c3'});

      // State filter
      final hidden = index.search(const CardSearchQuery(state: 'hidden'));
      expect(hidden.totalMatches, 1);
      expect(hidden.items.first.card.id, 'c2');

      // Combined filter: pack-b AND difficulty 1 AND active
      final combined = index.search(
        const CardSearchQuery(packId: 'pack-b', difficulty: 1, state: 'active'),
      );
      expect(combined.totalMatches, 1);
      expect(combined.items.first.card.id, 'c3');
    });

    test('sorts by name, difficulty, revision, and duplicatesFirst', () {
      final topics = [
        const TopicTaxonomy(
          id: 'topic-1',
          name: 'Topic 1',
          state: 'active',
          revision: 1,
        ),
      ];
      final packs = [
        const PackSummary(
          id: 'pack-1',
          topicId: 'topic-1',
          name: 'Pack 1',
          state: 'active',
          revision: 1,
          eligibleCardCount: 4,
          createdByUid: 'col-1',
        ),
      ];
      final cards = [
        const CardSummary(
          id: 'c-charlie',
          packId: 'pack-1',
          name: 'Charlie',
          difficulty: 3,
          state: 'active',
          revision: 1,
          imageReference: 'charlie.webp',
        ),
        const CardSummary(
          id: 'c-alice',
          packId: 'pack-1',
          name: 'Alice',
          difficulty: 1,
          state: 'active',
          revision: 10,
          imageReference: 'objects/9999999999999999999999999999999999999999999999999999999999999999.png',
        ),
        const CardSummary(
          id: 'c-bob',
          packId: 'pack-1',
          name: 'Bob',
          difficulty: 2,
          state: 'hidden',
          revision: 5,
          imageReference: 'bob.webp',
        ),
        const CardSummary(
          id: 'c-alice-clone',
          packId: 'pack-1',
          name: 'Alice Clone',
          difficulty: 1,
          state: 'active',
          revision: 2,
          imageReference: 'objects/9999999999999999999999999999999999999999999999999999999999999999.png',
        ),
      ];

      final index = DatasetSearchIndex.fromComponents(
        scope: const DatasetScope('proj', 'col-1', 'collector'),
        cards: cards,
        packs: packs,
        topics: topics,
      );

      // Name ascending
      final nameAsc = index.search(
        const CardSearchQuery(sort: CardSortOption.nameAsc),
      );
      expect(nameAsc.items.map((m) => m.card.name).toList(), [
        'Alice',
        'Alice Clone',
        'Bob',
        'Charlie',
      ]);

      // Name descending
      final nameDesc = index.search(
        const CardSearchQuery(sort: CardSortOption.nameDesc),
      );
      expect(nameDesc.items.map((m) => m.card.name).toList(), [
        'Charlie',
        'Bob',
        'Alice Clone',
        'Alice',
      ]);

      // Difficulty ascending
      final diffAsc = index.search(
        const CardSearchQuery(sort: CardSortOption.difficultyAsc),
      );
      expect(diffAsc.items.map((m) => m.card.difficulty).toList(), [
        1,
        1,
        2,
        3,
      ]);

      // Revision descending
      final revDesc = index.search(
        const CardSearchQuery(sort: CardSortOption.revisionDesc),
      );
      expect(revDesc.items.map((m) => m.card.revision).toList(), [10, 5, 2, 1]);

      // Duplicates first
      final dupsFirst = index.search(
        const CardSearchQuery(sort: CardSortOption.duplicatesFirst),
      );
      expect(dupsFirst.items[0].isByteDuplicate, isTrue);
      expect(dupsFirst.items[1].isByteDuplicate, isTrue);
      expect(dupsFirst.items[2].isByteDuplicate, isFalse);
      expect(dupsFirst.items[3].isByteDuplicate, isFalse);
    });

    test('paginates results accurately with page slicing', () {
      final cards = List.generate(
        75,
        (i) => CardSummary(
          id: 'card-$i',
          packId: 'pack-1',
          name: 'Card ${i.toString().padLeft(2, '0')}',
          difficulty: (i % 3) + 1,
          state: 'active',
          revision: 1,
          imageReference: 'card-$i.webp',
        ),
      );

      final topics = [
        const TopicTaxonomy(
          id: 'topic-1',
          name: 'Topic 1',
          state: 'active',
          revision: 1,
        ),
      ];
      final packs = [
        const PackSummary(
          id: 'pack-1',
          topicId: 'topic-1',
          name: 'Pack 1',
          state: 'active',
          revision: 1,
          eligibleCardCount: 75,
          createdByUid: 'col-1',
        ),
      ];

      final index = DatasetSearchIndex.fromComponents(
        scope: const DatasetScope('proj', 'col-1', 'collector'),
        cards: cards,
        packs: packs,
        topics: topics,
      );

      // Page 1 with pageSize 25
      final p1 = index.search(const CardSearchQuery(page: 1, pageSize: 25));
      expect(p1.totalMatches, 75);
      expect(p1.totalPages, 3);
      expect(p1.page, 1);
      expect(p1.items.length, 25);
      expect(p1.startIndex, 1);
      expect(p1.endIndex, 25);
      expect(p1.items.first.card.name, 'Card 00');
      expect(p1.items.last.card.name, 'Card 24');

      // Page 3 with pageSize 25
      final p3 = index.search(const CardSearchQuery(page: 3, pageSize: 25));
      expect(p3.page, 3);
      expect(p3.items.length, 25);
      expect(p3.startIndex, 51);
      expect(p3.endIndex, 75);
      expect(p3.items.first.card.name, 'Card 50');
      expect(p3.items.last.card.name, 'Card 74');

      // Out of bounds page clamps safely
      final p4 = index.search(const CardSearchQuery(page: 99, pageSize: 25));
      expect(p4.page, 3);
      expect(p4.items.length, 25);
    });

    test('account scoping: Collector only sees own packs; Owner sees all', () {
      final topics = [
        const TopicTaxonomy(
          id: 'topic-1',
          name: 'Permitted Topic',
          state: 'active',
          revision: 1,
        ),
      ];
      final collectorPacks = [
        const PackSummary(
          id: 'pack-col-1',
          topicId: 'topic-1',
          name: 'Collector 1 Pack',
          state: 'active',
          revision: 1,
          eligibleCardCount: 1,
          createdByUid: 'col-1',
        ),
      ];
      final collectorCards = [
        const CardSummary(
          id: 'c-col-1',
          packId: 'pack-col-1',
          name: 'Collector Card',
          difficulty: 1,
          state: 'active',
          revision: 1,
          imageReference: 'col1.webp',
        ),
      ];

      final collectorIndex = DatasetSearchIndex.fromComponents(
        scope: const DatasetScope('proj', 'col-1', 'collector'),
        cards: collectorCards,
        packs: collectorPacks,
        topics: topics,
      );

      expect(collectorIndex.scope.role, 'collector');
      expect(collectorIndex.scope.uid, 'col-1');
      expect(collectorIndex.packs.length, 1);
      expect(collectorIndex.cards.length, 1);

      // Search across collector index never reveals any foreign packs/cards
      final colSearch = collectorIndex.search(
        const CardSearchQuery(text: 'Pack'),
      );
      expect(colSearch.totalMatches, 1);
      expect(colSearch.items.first.packName, 'Collector 1 Pack');

      // Owner dataset: contains all packs from all creators
      final ownerPacks = [
        const PackSummary(
          id: 'pack-col-1',
          topicId: 'topic-1',
          name: 'Collector 1 Pack',
          state: 'active',
          revision: 1,
          eligibleCardCount: 1,
          createdByUid: 'col-1',
        ),
        const PackSummary(
          id: 'pack-col-2',
          topicId: 'topic-1',
          name: 'Collector 2 Pack',
          state: 'active',
          revision: 1,
          eligibleCardCount: 1,
          createdByUid: 'col-2',
        ),
      ];
      final ownerCards = [
        const CardSummary(
          id: 'c-col-1',
          packId: 'pack-col-1',
          name: 'Collector 1 Card',
          difficulty: 1,
          state: 'active',
          revision: 1,
          imageReference: 'col1.webp',
        ),
        const CardSummary(
          id: 'c-col-2',
          packId: 'pack-col-2',
          name: 'Collector 2 Card',
          difficulty: 2,
          state: 'active',
          revision: 1,
          imageReference: 'col2.webp',
        ),
      ];

      final ownerIndex = DatasetSearchIndex.fromComponents(
        scope: const DatasetScope('proj', 'owner-uid', 'owner_admin'),
        cards: ownerCards,
        packs: ownerPacks,
        topics: topics,
      );

      expect(ownerIndex.scope.role, 'owner_admin');
      expect(ownerIndex.packs.length, 2);
      expect(ownerIndex.cards.length, 2);

      final ownerSearch = ownerIndex.search(
        const CardSearchQuery(text: 'Card'),
      );
      expect(ownerSearch.totalMatches, 2);
    });

    test('performance benchmark: 5,000 cards indexed and searched with sub-millisecond to low-millisecond timing', () {
      const cardCount = 5000;
      const packCount = 50;

      final topics = [
        const TopicTaxonomy(
          id: 'topic-perf',
          name: 'Performance Topic',
          state: 'active',
          revision: 1,
        ),
      ];

      final packs = List.generate(
        packCount,
        (i) => PackSummary(
          id: 'pack-$i',
          topicId: 'topic-perf',
          name: 'Pack $i for Performance Benchmark',
          state: 'active',
          eligibleCardCount: cardCount ~/ packCount,
          revision: 1,
          createdByUid: 'bench-user',
        ),
      );

      final names = [
        'Naruto Uzumaki',
        'Sasuke Uchiha',
        'Sakura Haruno',
        'Kakashi Hatake',
        'Itachi Uchiha',
        'Hinata Hyuga',
        'Gaara of the Sand',
        'Jiraiya the Gallant',
        'Tsunade Senju',
        'Orochimaru Snake',
      ];

      final cards = List.generate(cardCount, (i) {
        final packIndex = i % packCount;
        final baseName = names[i % names.length];
        final name = '$baseName #$i';
        // Inject intentional duplicate hashes every 20 cards
        final isDupHash = i % 20 == 0;
        final hash = isDupHash
            ? 'objects/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png'
            : 'objects/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb$i.png';
        // Inject intentional incomplete image every 25 cards
        final isIncomplete = i % 25 == 0;

        return CardSummary(
          id: 'card-$i',
          packId: 'pack-$packIndex',
          name: name,
          difficulty: (i % 3) + 1,
          state: i % 10 == 0 ? 'hidden' : 'active',
          revision: (i % 5) + 1,
          imageReference: isIncomplete ? null : hash,
        );
      });

      // Measure index construction time
      final stopwatchBuild = Stopwatch()..start();
      final index = DatasetSearchIndex.fromComponents(
        scope: const DatasetScope('proj', 'bench-user', 'collector'),
        cards: cards,
        packs: packs,
        topics: topics,
      );
      stopwatchBuild.stop();

      // Building 5,000 cards index should be fast (< 2000ms in debug test runner)
      expect(index.cards.length, cardCount);
      expect(stopwatchBuild.elapsedMilliseconds, lessThan(2000));

      // Test 1: Full text search across 5,000 cards
      final sw1 = Stopwatch()..start();
      final textResult = index.search(const CardSearchQuery(text: 'Uchiha'));
      sw1.stop();
      expect(textResult.totalMatches, greaterThan(0));
      expect(sw1.elapsedMilliseconds, lessThan(35));

      // Test 2: Filter by duplicate image bytes
      final sw2 = Stopwatch()..start();
      final dupResult = index.search(
        const CardSearchQuery(duplicateFilter: DuplicateFilter.byteDuplicate),
      );
      sw2.stop();
      expect(dupResult.totalMatches, greaterThan(0));
      expect(sw2.elapsedMilliseconds, lessThan(20));

      // Test 3: Complex multi-dimensional filter (pack + difficulty + state + pagination + sort)
      final sw3 = Stopwatch()..start();
      final multiResult = index.search(
        const CardSearchQuery(
          packId: 'pack-0',
          difficulty: 1,
          state: 'active',
          sort: CardSortOption.nameAsc,
          page: 1,
          pageSize: 20,
        ),
      );
      sw3.stop();
      expect(multiResult.items.length, lessThanOrEqualTo(20));
      expect(sw3.elapsedMilliseconds, lessThan(20));
    });
  });
}
