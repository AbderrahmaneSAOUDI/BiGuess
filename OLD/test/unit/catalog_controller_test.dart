import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:biguess/data/catalog/catalog_models.dart';
import 'package:biguess/data/catalog/catalog_repository.dart';
import 'package:biguess/domain/models/card.dart';
import 'package:biguess/domain/models/difficulty.dart';
import 'package:biguess/domain/models/pack.dart';
import 'package:biguess/domain/models/pack_selection.dart';
import 'package:biguess/domain/models/topic.dart';
import 'package:biguess/domain/repositories/content_repository.dart';
import 'package:biguess/domain/use_cases/select_packs_use_case.dart';
import 'package:biguess/providers/catalog_controller.dart';
import 'package:biguess/providers/pack_selection_controller.dart';
import 'package:biguess/providers/topic_pack_providers.dart';

class LocalCatalogContent implements ContentRepository {
  @override
  List<Topic> getTopics() => [Topic(id: 'local-topic', name: 'Local Topic')];
  @override
  List<Pack> getPacksForTopic(String topicId) => topicId == 'local-topic'
      ? [Pack(id: 'installed', topicId: topicId, name: 'Installed Pack')]
      : [];
  @override
  List<Card> getCardsForPack(String packId) =>
      getInstalledCardsForPack(packId) ?? [];
  @override
  List<Card>? getInstalledCardsForPack(String packId) => packId == 'installed'
      ? [
          for (var i = 0; i < 2; i++)
            Card(
              id: 'card-$i',
              packId: packId,
              name: 'Card $i',
              imageReference: 'assets/logos/biguess-icon.webp',
              difficulty: Difficulty.easy,
            ),
        ]
      : null;
}

CatalogSnapshot catalogFixture({bool removed = false}) => CatalogSnapshot(
  origin: 'https://catalog.example',
  topics: [
    const CatalogTopicSummary(
      id: 'remote-topic',
      name: 'Online Topic',
      revision: 1,
    ),
    CatalogTopicSummary(
      id: 'local-topic',
      name: 'Server rename must not change local snapshot',
      revision: 9,
      available: !removed,
    ),
  ],
  packs: [
    CatalogPackSummary(
      id: 'remote-pack',
      topicId: 'remote-topic',
      name: 'Online Pack',
      revision: 1,
      cardCount: 50,
      manifestSha256: 'a' * 64,
    ),
    CatalogPackSummary(
      id: 'empty-pack',
      topicId: 'remote-topic',
      name: 'Empty Online Pack',
      revision: 1,
      cardCount: 0,
      manifestSha256: 'b' * 64,
    ),
    CatalogPackSummary(
      id: 'installed',
      topicId: 'local-topic',
      name: 'Server rename',
      revision: 9,
      cardCount: 99,
      manifestSha256: 'c' * 64,
      available: !removed,
    ),
  ],
  topicsCheckedAt: DateTime.utc(2026, 11, 11),
  packsCheckedAt: {'remote-topic': DateTime.utc(2026, 11, 11)},
);

class FakeCatalogRepository implements CatalogRepository {
  CatalogSnapshot? cached;
  CatalogSnapshot? incoming;
  bool fail = false;
  int topicsCalls = 0, packsCalls = 0, reads = 0;
  FakeCatalogRepository({this.cached});
  @override
  Future<CatalogSnapshot?> readCached() async {
    reads++;
    return cached;
  }

  @override
  Future<CatalogSnapshot> refreshTopics() async {
    topicsCalls++;
    if (fail) throw const CatalogFailure('catalog-unavailable');
    return cached = incoming ?? catalogFixture();
  }

  @override
  Future<CatalogSnapshot> refreshPacks(String topicId) async {
    packsCalls++;
    if (fail) throw const CatalogFailure('catalog-unavailable');
    return cached = incoming ?? catalogFixture();
  }

  @override
  void close() {}
}

void main() {
  late ProviderContainer container;
  late FakeCatalogRepository repository;
  setUp(() {
    repository = FakeCatalogRepository();
    container = ProviderContainer(
      overrides: [
        contentRepositoryProvider.overrideWithValue(LocalCatalogContent()),
        publicCatalogRepositoryProvider.overrideWithValue(repository),
      ],
    );
  });
  tearDown(() => container.dispose());
  Future<void> settleCache() async {
    container.read(catalogBrowseProvider);
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'startup/rebuild only read disk; no requests until explicit discovery',
    () async {
      await settleCache();
      for (var i = 0; i < 5; i++) {
        container.read(browseTopicsProvider);
        container.read(browsePacksProvider('local-topic'));
      }
      expect(repository.reads, 1);
      expect(repository.topicsCalls, 0);
      expect(repository.packsCalls, 0);
      await container.read(catalogBrowseProvider.notifier).refreshTopics();
      expect(repository.topicsCalls, 1);
      expect(container.read(browseTopicsProvider).map((r) => r.topic.id), [
        'local-topic',
        'remote-topic',
      ]);
    },
  );
  test(
    'offline cached summaries browse but never become installed Cards or selectable Packs',
    () async {
      repository.cached = catalogFixture();
      repository.fail = true;
      await settleCache();
      final packs = container.read(browsePacksProvider('remote-topic'));
      expect(packs.first.availability, PackAvailability.downloadRequired);
      expect(packs.last.availability, PackAvailability.unavailable);
      expect(packs.first.cardCount, 50);
      expect(packs.every((p) => !p.installed), true);
      expect(
        container
            .read(contentRepositoryProvider)
            .getInstalledCardsForPack('remote-pack'),
        isNull,
      );
      expect(
        () => container.read(selectPacksUseCaseProvider)(
          PackSelection(topicId: 'remote-topic', packIds: ['remote-pack']),
        ),
        throwsA(isA<PackSelectionException>()),
      );
      await container.read(catalogBrowseProvider.notifier).refreshTopics();
      expect(
        container.read(catalogBrowseProvider).error,
        'catalog-unavailable',
      );
      expect(
        container.read(browsePacksProvider('local-topic')).single.availability,
        PackAvailability.playable,
      );
    },
  );
  test(
    'public disappearance does not overwrite, remove or rename installed content',
    () async {
      repository.cached = catalogFixture();
      repository.incoming = catalogFixture(removed: true);
      await settleCache();
      await container.read(catalogBrowseProvider.notifier).refreshTopics();
      final local = container.read(browseTopicsProvider).first;
      expect(local.topic.name, 'Local Topic');
      expect(local.unavailableOnline, true);
      final pack = container.read(browsePacksProvider('local-topic')).single;
      expect(pack.pack.name, 'Installed Pack');
      expect(pack.cardCount, 2);
      expect(pack.installed, true);
      expect(pack.unavailableOnline, true);
      expect(pack.availability, PackAvailability.playable);
      final pool = container.read(selectPacksUseCaseProvider)(
        PackSelection(topicId: 'local-topic', packIds: ['installed']),
      );
      expect(pool.cards, hasLength(2));
    },
  );
  test(
    'opening uncached remote Topic discovers once; failures never cause automatic retries',
    () async {
      repository.cached = CatalogSnapshot(
        origin: 'https://catalog.example',
        topics: catalogFixture().topics,
        packs: [],
      );
      repository.fail = true;
      await settleCache();
      final controller = container.read(catalogBrowseProvider.notifier);
      await controller.ensurePacks('remote-topic');
      await controller.ensurePacks('remote-topic');
      await controller.ensurePacks('unknown-legacy-topic');
      expect(repository.packsCalls, 1);
      await controller.refreshPacks('remote-topic');
      expect(repository.packsCalls, 2);
    },
  );
  test(
    'remote ID/parent conflict never moves a locally installed Pack',
    () async {
      final current = catalogFixture();
      repository.cached = CatalogSnapshot(
        origin: current.origin,
        topics: current.topics,
        packs: [
          CatalogPackSummary(
            id: 'installed',
            topicId: 'remote-topic',
            name: 'Conflicting remote parent',
            revision: 8,
            cardCount: 100,
            manifestSha256: 'd' * 64,
          ),
        ],
      );
      await settleCache();
      expect(
        container.read(browsePacksProvider('remote-topic')).single.availability,
        PackAvailability.unavailable,
      );
      final local = container.read(browsePacksProvider('local-topic')).single;
      expect(local.pack.topicId, 'local-topic');
      expect(local.pack.name, 'Installed Pack');
      expect(local.availability, PackAvailability.playable);
      expect(local.cardCount, 2);
    },
  );
}
