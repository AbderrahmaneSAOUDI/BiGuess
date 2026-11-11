import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/catalog/catalog_cache_store.dart';
import '../data/catalog/catalog_models.dart';
import '../data/catalog/catalog_repository.dart';
import '../domain/models/pack.dart';
import '../domain/models/topic.dart';
import '../domain/use_cases/select_packs_use_case.dart';
import 'pack_selection_controller.dart';
import 'topic_pack_providers.dart';
import 'gameplay_network_gate.dart';

/// Public endpoint only. An empty default keeps existing local builds inert.
final publicCatalogBaseUriProvider = Provider<Uri?>((ref) {
  const configured = String.fromEnvironment('BIGUESS_CONTENT_API_BASE_URL');
  if (configured.isEmpty) return null;
  final uri = Uri.tryParse(configured);
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      !{'', '/'}.contains(uri.path) ||
      !(uri.scheme == 'https' ||
          uri.scheme == 'http' &&
              {'localhost', '127.0.0.1', '::1'}.contains(uri.host))) {
    return null;
  }
  return uri;
});

final publicCatalogRepositoryProvider = Provider<CatalogRepository?>((ref) {
  if (ref.watch(gameplayNetworkBlockedProvider)) return null;
  final base = ref.watch(publicCatalogBaseUriProvider);
  if (base == null) return null;
  final namespace = sha256.convert(utf8.encode(base.origin)).toString();
  final repository = HttpCatalogRepository(
    base: base,
    store: FileCatalogCacheStore(() async {
      final directory = await getApplicationSupportDirectory();
      return File(p.join(directory.path, 'public_catalog_v1_$namespace.json'));
    }),
  );
  ref.onDispose(repository.close);
  return repository;
});

class CatalogBrowseState {
  const CatalogBrowseState({
    this.snapshot,
    this.loading = false,
    this.configured = false,
    this.error,
  });
  final CatalogSnapshot? snapshot;
  final bool loading, configured;
  final String? error;
}

/// Reading the saved summaries is local IO only. All network methods are invoked
/// by discovery gestures, never builds, app launch or gameplay transitions.
class CatalogController extends Notifier<CatalogBrowseState> {
  int _generation = 0;
  bool _disposed = false;
  Future<void> _reading = Future.value();
  final _attemptedTopics = <String>{};

  @override
  CatalogBrowseState build() {
    final repository = ref.watch(publicCatalogRepositoryProvider);
    final generation = ++_generation;
    _disposed = false;
    _attemptedTopics.clear();
    ref.onDispose(() {
      _disposed = true;
      _generation++;
    });
    if (repository == null) return const CatalogBrowseState();
    _reading = Future<void>.microtask(() async {
      try {
        final cached = await repository.readCached();
        if (!_current(generation)) return;
        state = CatalogBrowseState(snapshot: cached, configured: true);
      } catch (_) {
        if (!_current(generation)) return;
        state = const CatalogBrowseState(
          configured: true,
          error: 'cache-unavailable',
        );
      }
    });
    return const CatalogBrowseState(configured: true, loading: true);
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  Future<void> refreshTopics() =>
      _run((repository) => repository.refreshTopics());
  Future<void> refreshPacks(String topicId) =>
      _run((repository) => repository.refreshPacks(topicId));

  /// An explicit Topic navigation may load its first missing Pack summary list.
  /// A failed attempt requires manual Refresh rather than rebuild/re-entry retry.
  Future<void> ensurePacks(String topicId) async {
    final generation = _generation;
    await _reading;
    if (!_current(generation) ||
        state.loading ||
        state.snapshot?.packsCheckedAt.containsKey(topicId) == true ||
        !(state.snapshot?.topics.any((t) => t.id == topicId && t.available) ??
            false) ||
        !_attemptedTopics.add(topicId)) {
      return;
    }
    await refreshPacks(topicId);
  }

  Future<void> _run(
    Future<CatalogSnapshot> Function(CatalogRepository) action,
  ) async {
    if (ref.read(gameplayNetworkBlockedProvider)) return;
    final generation = _generation;
    await _reading;
    if (!_current(generation) ||
        state.loading ||
        ref.read(gameplayNetworkBlockedProvider)) {
      return;
    }
    final repository = ref.read(publicCatalogRepositoryProvider);
    if (repository == null) return;
    final prior = state.snapshot;
    state = CatalogBrowseState(
      snapshot: prior,
      configured: true,
      loading: true,
    );
    try {
      final next = await action(repository);
      if (_current(generation)) {
        state = CatalogBrowseState(snapshot: next, configured: true);
      }
    } catch (_) {
      if (_current(generation)) {
        state = CatalogBrowseState(
          snapshot: prior,
          configured: true,
          error: 'catalog-unavailable',
        );
      }
    }
  }
}

final catalogBrowseProvider =
    NotifierProvider<CatalogController, CatalogBrowseState>(
      CatalogController.new,
    );

class BrowseTopic {
  const BrowseTopic(this.topic, {required this.local, this.summary});
  final Topic topic;
  final bool local;
  final CatalogTopicSummary? summary;
  bool get unavailableOnline => summary?.available == false;
}

/// Cached summaries supplement browsing; local metadata retains ID/parent/name
/// authority for installed content. Nothing is injected into gameplay providers.
final browseTopicsProvider = Provider<List<BrowseTopic>>((ref) {
  final repository = ref.watch(contentRepositoryProvider);
  final catalog = ref.watch(catalogBrowseProvider).snapshot;
  final summaries = {
    for (final topic in catalog?.topics ?? <CatalogTopicSummary>[])
      topic.id: topic,
  };
  final rows = <BrowseTopic>[];
  for (final topic in repository.getTopics()) {
    rows.add(
      BrowseTopic(topic, local: true, summary: summaries.remove(topic.id)),
    );
  }
  for (final topic in summaries.values) {
    rows.add(
      BrowseTopic(
        Topic(
          id: topic.id,
          name: topic.name,
          revision: topic.revision,
          published: topic.available,
        ),
        local: false,
        summary: topic,
      ),
    );
  }
  return List.unmodifiable(rows);
});

class BrowsePack {
  const BrowsePack({
    required this.pack,
    required this.availability,
    required this.cardCount,
    required this.installed,
    this.unavailableOnline = false,
  });
  final Pack pack;
  final PackAvailability availability;
  final int cardCount;
  final bool installed, unavailableOnline;
}

final browsePacksProvider = Provider.family<List<BrowsePack>, String>((
  ref,
  topicId,
) {
  final repository = ref.watch(contentRepositoryProvider);
  final options = ref.watch(packOptionsProvider(topicId));
  final snapshot = ref.watch(catalogBrowseProvider).snapshot;
  final remoteTopic = snapshot?.topics
      .where((t) => t.id == topicId)
      .firstOrNull;
  final summaries = {
    for (final pack
        in snapshot?.packsForTopic(topicId) ?? <CatalogPackSummary>[])
      pack.id: pack,
  };
  final rows = <BrowsePack>[];
  final allLocal = {
    for (final topic in repository.getTopics())
      for (final pack in repository.getPacksForTopic(topic.id)) pack.id: pack,
  };
  for (final option in options) {
    final summary = summaries.remove(option.pack.id);
    final installed =
        repository.getInstalledCardsForPack(option.pack.id) != null;
    rows.add(
      BrowsePack(
        pack: option.pack,
        availability: option.availability,
        cardCount: option.cards.length,
        installed: installed,
        unavailableOnline:
            remoteTopic?.available == false || summary?.available == false,
      ),
    );
  }
  for (final pack in summaries.values) {
    final conflictingLocal = allLocal[pack.id];
    final unavailable =
        !pack.available ||
        remoteTopic?.available == false ||
        pack.cardCount == 0 ||
        conflictingLocal != null;
    rows.add(
      BrowsePack(
        pack: Pack(
          id: pack.id,
          topicId: topicId,
          name: pack.name,
          revision: pack.revision,
          published: !unavailable,
        ),
        availability: unavailable
            ? PackAvailability.unavailable
            : PackAvailability.downloadRequired,
        cardCount: pack.cardCount,
        installed: false,
        unavailableOnline: unavailable,
      ),
    );
  }
  return List.unmodifiable(rows);
});
