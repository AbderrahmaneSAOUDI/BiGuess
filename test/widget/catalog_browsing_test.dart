import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:biguess/core/theme/app_theme.dart';
import 'package:biguess/data/catalog/catalog_models.dart';
import 'package:biguess/data/catalog/catalog_cache_store.dart';
import 'package:biguess/data/catalog/catalog_repository.dart';
import 'package:biguess/presentation/screens/topics/topics_screen.dart';
import 'package:biguess/presentation/screens/game/game_configuration_screen.dart';
import 'package:biguess/providers/catalog_controller.dart';
import 'package:biguess/providers/topic_pack_providers.dart';

import '../unit/catalog_controller_test.dart'
    show LocalCatalogContent, FakeCatalogRepository, catalogFixture;

class _NoCatalogNetwork extends HttpOverrides {
  int clients = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    clients++;
    throw StateError(
      'No client may be allocated while browsing cached content',
    );
  }
}

void main() {
  Future<void> show(
    WidgetTester tester,
    FakeCatalogRepository catalog, {
    bool narrow = false,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = narrow
        ? const Size(360, 800)
        : const Size(480, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          contentRepositoryProvider.overrideWithValue(LocalCatalogContent()),
          publicCatalogRepositoryProvider.overrideWithValue(catalog),
          automaticUpdateChecksProvider.overrideWithValue(false),
        ],
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const TopicsScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        finder,
        180,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets(
    'launch/rebuild stay local; explicit discovery and Topic gesture fetch summaries without installing Cards',
    (tester) async {
      final catalog = FakeCatalogRepository();
      catalog.incoming = CatalogSnapshot(
        origin: 'https://catalog.example',
        topics: catalogFixture().topics,
        packs: [],
        topicsCheckedAt: DateTime.utc(2026, 11, 11),
      );
      await show(tester, catalog);
      expect(find.text('Local Topic'), findsOneWidget);
      expect(catalog.topicsCalls, 0);
      expect(catalog.packsCalls, 0);
      await tap(tester, find.text('Discover online content'));
      expect(find.text('Online Topic'), findsOneWidget);
      expect(catalog.topicsCalls, 1);
      expect(catalog.packsCalls, 0);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(TopicsScreen)),
      );
      container.invalidate(browseTopicsProvider);
      await tester.pump();
      expect(catalog.topicsCalls, 1);
      catalog.incoming = catalogFixture();
      await tap(tester, find.text('Online Topic'));
      expect(catalog.packsCalls, 1);
      expect(find.text('Not downloaded'), findsOneWidget);
      expect(find.text('Unavailable'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('pack-remote-pack')));
      expect(find.byType(GameConfigurationScreen), findsNothing);
      expect(
        container
            .read(contentRepositoryProvider)
            .getInstalledCardsForPack('remote-pack'),
        isNull,
      );
    },
  );

  testWidgets(
    'backend down retains cached unavailable labels and locally installed Pack navigation',
    (tester) async {
      final catalog = FakeCatalogRepository(
        cached: catalogFixture(removed: true),
      )..fail = true;
      await show(tester, catalog);
      expect(catalog.topicsCalls, 0);
      await tap(tester, find.text('Refresh catalog'));
      expect(
        find.textContaining('Online content could not be refreshed'),
        findsOneWidget,
      );
      await tap(tester, find.text('Local Topic'));
      expect(
        find.text('Installed · 2 items\nUnavailable online'),
        findsOneWidget,
      );
      await tap(tester, find.byKey(const ValueKey('pack-installed')));
      expect(find.byType(GameConfigurationScreen), findsOneWidget);
      expect(find.text('2 eligible cards'), findsOneWidget);
    },
  );

  testWidgets(
    'saved remote summaries are usable without refresh on narrow viewport',
    (tester) async {
      final catalog = FakeCatalogRepository(cached: catalogFixture())
        ..fail = true;
      await show(tester, catalog, narrow: true, textScale: 2);
      await tap(tester, find.text('Online Topic'));
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('pack-remote-pack')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Online Pack'), findsOneWidget);
      expect(find.text('Not downloaded'), findsOneWidget);
      expect(catalog.topicsCalls, 0);
      expect(catalog.packsCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'configured real repository restores cache on launch without allocating HTTP clients',
    (tester) async {
      final old = HttpOverrides.current;
      final trap = _NoCatalogNetwork();
      HttpOverrides.global = trap;
      final fixture = catalogFixture();
      final store = MemoryCatalogCacheStore()
        ..value = CatalogSnapshot(
          origin: fixture.origin,
          topics: fixture.topics,
          packs: fixture.packs,
          topicsCheckedAt: fixture.topicsCheckedAt,
          packsCheckedAt: {
            for (final topic in fixture.topics)
              topic.id: DateTime.utc(2026, 11, 11),
          },
        );
      final repository = HttpCatalogRepository(
        base: Uri.parse(fixture.origin),
        store: store,
      );
      try {
        expect(HttpOverrides.current, same(trap));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              contentRepositoryProvider.overrideWithValue(
                LocalCatalogContent(),
              ),
              publicCatalogRepositoryProvider.overrideWithValue(repository),
              automaticUpdateChecksProvider.overrideWithValue(false),
            ],
            child: const MaterialApp(home: TopicsScreen()),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(find.text('Online Topic'), findsOneWidget);
        expect(find.text('Local Topic'), findsOneWidget);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(TopicsScreen)),
        );
        container.invalidate(browseTopicsProvider);
        await tester.pump(const Duration(seconds: 5));
        expect(trap.clients, 0);
        expect(tester.takeException(), isNull);
      } finally {
        repository.close();
        HttpOverrides.global = old;
      }
    },
  );
}
