import 'dart:math' as math;

import 'card_summary.dart';
import 'dataset_controller.dart';
import 'pack_summary.dart';
import 'studio_dataset.dart';
import 'topic_taxonomy.dart';

/// Filter options for duplicate detection.
enum DuplicateFilter {
  all,
  anyDuplicate,
  byteDuplicate,
  nameDuplicate,
  similarName,
}

/// Sort options for search results.
enum CardSortOption {
  nameAsc,
  nameDesc,
  difficultyAsc,
  difficultyDesc,
  revisionAsc,
  revisionDesc,
  status,
  duplicatesFirst,
}

/// Query parameters for searching and filtering the local dataset.
class CardSearchQuery {
  const CardSearchQuery({
    this.text = '',
    this.packId,
    this.topicId,
    this.difficulty,
    this.state,
    this.draftStatus,
    this.incompleteImageOnly = false,
    this.duplicateFilter = DuplicateFilter.all,
    this.sort = CardSortOption.nameAsc,
    this.page = 1,
    this.pageSize = 50,
  });

  final String text;
  final String? packId;
  final String? topicId;
  final int? difficulty;
  final String? state;
  final DraftStatus? draftStatus;
  final bool incompleteImageOnly;
  final DuplicateFilter duplicateFilter;
  final CardSortOption sort;
  final int page;
  final int pageSize;

  bool get isFiltered =>
      text.trim().isNotEmpty ||
      packId != null ||
      topicId != null ||
      difficulty != null ||
      state != null ||
      draftStatus != null ||
      incompleteImageOnly ||
      duplicateFilter != DuplicateFilter.all ||
      sort != CardSortOption.nameAsc;

  CardSearchQuery copyWith({
    String? text,
    String? packId,
    bool clearPackId = false,
    String? topicId,
    bool clearTopicId = false,
    int? difficulty,
    bool clearDifficulty = false,
    String? state,
    bool clearState = false,
    DraftStatus? draftStatus,
    bool clearDraftStatus = false,
    bool? incompleteImageOnly,
    DuplicateFilter? duplicateFilter,
    CardSortOption? sort,
    int? page,
    int? pageSize,
  }) => CardSearchQuery(
    text: text ?? this.text,
    packId: clearPackId ? null : (packId ?? this.packId),
    topicId: clearTopicId ? null : (topicId ?? this.topicId),
    difficulty: clearDifficulty ? null : (difficulty ?? this.difficulty),
    state: clearState ? null : (state ?? this.state),
    draftStatus: clearDraftStatus ? null : (draftStatus ?? this.draftStatus),
    incompleteImageOnly: incompleteImageOnly ?? this.incompleteImageOnly,
    duplicateFilter: duplicateFilter ?? this.duplicateFilter,
    sort: sort ?? this.sort,
    page: page ?? this.page,
    pageSize: pageSize ?? this.pageSize,
  );
}

/// A matched card with associated duplicate detection flags and context.
class CardSearchMatch {
  const CardSearchMatch({
    required this.card,
    required this.packName,
    required this.topicName,
    required this.topicId,
    this.isByteDuplicate = false,
    this.byteDuplicateCardIds = const [],
    this.isNameDuplicate = false,
    this.nameDuplicateCardIds = const [],
    this.isSimilarName = false,
    this.similarNameCardIds = const [],
    this.isIncompleteImage = false,
  });

  final CardSummary card;
  final String packName;
  final String topicName;
  final String topicId;
  final bool isByteDuplicate;
  final List<String> byteDuplicateCardIds;
  final bool isNameDuplicate;
  final List<String> nameDuplicateCardIds;
  final bool isSimilarName;
  final List<String> similarNameCardIds;
  final bool isIncompleteImage;

  bool get hasAnyDuplicate =>
      isByteDuplicate || isNameDuplicate || isSimilarName;
}

/// Summary counts across the current dataset scope.
class SearchSummaryCounts {
  const SearchSummaryCounts({
    required this.totalCards,
    required this.byteDuplicatesCount,
    required this.nameDuplicatesCount,
    required this.similarNamesCount,
    required this.incompleteImagesCount,
  });

  final int totalCards;
  final int byteDuplicatesCount;
  final int nameDuplicatesCount;
  final int similarNamesCount;
  final int incompleteImagesCount;
}

/// Results of a search and filter query.
class CardSearchResult {
  const CardSearchResult({
    required this.items,
    required this.totalMatches,
    required this.page,
    required this.pageSize,
    required this.totalPages,
    required this.matchingTopics,
    required this.matchingPacks,
    required this.summary,
  });

  final List<CardSearchMatch> items;
  final int totalMatches;
  final int page;
  final int pageSize;
  final int totalPages;
  final List<TopicTaxonomy> matchingTopics;
  final List<PackSummary> matchingPacks;
  final SearchSummaryCounts summary;

  int get startIndex => totalMatches == 0 ? 0 : (page - 1) * pageSize + 1;
  int get endIndex => math.min(page * pageSize, totalMatches);
}

/// High-performance, account-scoped in-memory index for search, filters,
/// and duplicate detection over authorized Studio records.
class DatasetSearchIndex {
  DatasetSearchIndex._({
    required this.scope,
    required this.cards,
    required this.packs,
    required this.topics,
    required this.summaryCounts,
    required this._matchesById,
    required this._tokenIndex,
    required this._packToCardIds,
    required this._topicToCardIds,
    required this._difficultyToCardIds,
    required this._stateToCardIds,
    required this._incompleteImageCardIds,
    required this._byteDuplicateCardIds,
    required this._nameDuplicateCardIds,
    required this._similarNameCardIds,
  });

  final DatasetScope scope;
  final List<CardSummary> cards;
  final List<PackSummary> packs;
  final List<TopicTaxonomy> topics;
  final SearchSummaryCounts summaryCounts;

  final Map<String, CardSearchMatch> _matchesById;
  final Map<String, Set<String>> _tokenIndex;
  final Map<String, Set<String>> _packToCardIds;
  final Map<String, Set<String>> _topicToCardIds;
  final Map<int, Set<String>> _difficultyToCardIds;
  final Map<String, Set<String>> _stateToCardIds;
  final Set<String> _incompleteImageCardIds;
  final Set<String> _byteDuplicateCardIds;
  final Set<String> _nameDuplicateCardIds;
  final Set<String> _similarNameCardIds;

  /// Builds a new index from the controller's current state.
  factory DatasetSearchIndex.build(DatasetController controller) {
    final scope = controller.scope;
    if (scope == null) {
      return DatasetSearchIndex.empty(const DatasetScope('', '', ''));
    }
    return DatasetSearchIndex.fromComponents(
      scope: scope,
      cards: controller.cards,
      packs: controller.packs,
      topics: controller.topics,
    );
  }

  /// Builds a new index directly from dataset components.
  factory DatasetSearchIndex.fromComponents({
    required DatasetScope scope,
    required List<CardSummary> cards,
    required List<PackSummary> packs,
    required List<TopicTaxonomy> topics,
  }) {
    final packMap = {for (final p in packs) p.id: p};
    final topicMap = {for (final t in topics) t.id: t};

    // 1. Group by image content hash (Byte Duplicates)
    final hashToCardIds = <String, List<String>>{};
    final incompleteImageIds = <String>{};

    for (final card in cards) {
      final hash = _extractImageHash(card);
      if (hash != null && hash.isNotEmpty) {
        hashToCardIds.putIfAbsent(hash, () => []).add(card.id);
      } else {
        incompleteImageIds.add(card.id);
      }
    }

    final byteDuplicateIds = <String>{};
    final byteDuplicatesByCardId = <String, List<String>>{};
    for (final entry in hashToCardIds.entries) {
      if (entry.value.length > 1) {
        byteDuplicateIds.addAll(entry.value);
        for (final id in entry.value) {
          byteDuplicatesByCardId[id] = entry.value
              .where((other) => other != id)
              .toList();
        }
      }
    }

    // 2. Group by exact normalized name within Pack (Name Duplicates)
    final packAndNameToCardIds = <String, List<String>>{};
    for (final card in cards) {
      final key = '${card.packId}:${_normalize(card.name)}';
      packAndNameToCardIds.putIfAbsent(key, () => []).add(card.id);
    }

    final nameDuplicateIds = <String>{};
    final nameDuplicatesByCardId = <String, List<String>>{};
    for (final entry in packAndNameToCardIds.entries) {
      if (entry.value.length > 1) {
        nameDuplicateIds.addAll(entry.value);
        for (final id in entry.value) {
          nameDuplicatesByCardId[id] = entry.value
              .where((other) => other != id)
              .toList();
        }
      }
    }

    // 3. Similar names within the same Pack
    final similarNameIds = <String>{};
    final similarNamesByCardId = <String, List<String>>{};

    // Group cards by pack for local pairwise comparison
    final metasByPack = <String, List<_CardNameMeta>>{};
    for (final card in cards) {
      metasByPack.putIfAbsent(card.packId, () => []).add(_CardNameMeta(card));
    }

    for (final packMetas in metasByPack.values) {
      final count = packMetas.length;
      for (var i = 0; i < count; i++) {
        final a = packMetas[i];
        for (var j = i + 1; j < count; j++) {
          final b = packMetas[j];
          if (a.normalized == b.normalized) {
            continue; // exact duplicate already tracked
          }
          if (_areSimilarNamesMeta(a, b)) {
            similarNameIds.add(a.card.id);
            similarNameIds.add(b.card.id);
            similarNamesByCardId
                .putIfAbsent(a.card.id, () => [])
                .add(b.card.id);
            similarNamesByCardId
                .putIfAbsent(b.card.id, () => [])
                .add(a.card.id);
          }
        }
      }
    }

    // 4. Inverted indices
    final matchesById = <String, CardSearchMatch>{};
    final tokenIndex = <String, Set<String>>{};
    final packToCardIds = <String, Set<String>>{};
    final topicToCardIds = <String, Set<String>>{};
    final difficultyToCardIds = <int, Set<String>>{};
    final stateToCardIds = <String, Set<String>>{};

    for (final card in cards) {
      final pack = packMap[card.packId];
      final packName = pack?.name ?? card.packId;
      final topicId = pack?.topicId ?? '';
      final topic = topicMap[topicId];
      final topicName = topic?.name ?? topicId;

      final isByteDup = byteDuplicateIds.contains(card.id);
      final isNameDup = nameDuplicateIds.contains(card.id);
      final isSimilar = similarNameIds.contains(card.id);
      final isIncomplete = incompleteImageIds.contains(card.id);

      final match = CardSearchMatch(
        card: card,
        packName: packName,
        topicName: topicName,
        topicId: topicId,
        isByteDuplicate: isByteDup,
        byteDuplicateCardIds: byteDuplicatesByCardId[card.id] ?? const [],
        isNameDuplicate: isNameDup,
        nameDuplicateCardIds: nameDuplicatesByCardId[card.id] ?? const [],
        isSimilarName: isSimilar,
        similarNameCardIds: similarNamesByCardId[card.id] ?? const [],
        isIncompleteImage: isIncomplete,
      );
      matchesById[card.id] = match;

      // Pack & Topic sets
      packToCardIds.putIfAbsent(card.packId, () => {}).add(card.id);
      if (topicId.isNotEmpty) {
        topicToCardIds.putIfAbsent(topicId, () => {}).add(card.id);
      }

      // Difficulty
      difficultyToCardIds.putIfAbsent(card.difficulty, () => {}).add(card.id);

      // State
      stateToCardIds.putIfAbsent(card.state, () => {}).add(card.id);

      // Token index: tokenizes card name, card id, pack name, topic name
      final tokens = <String>{
        ..._tokenize(card.name),
        ..._tokenize(card.id),
        ..._tokenize(packName),
        ..._tokenize(topicName),
      };
      for (final token in tokens) {
        tokenIndex.putIfAbsent(token, () => {}).add(card.id);
      }
    }

    final summaryCounts = SearchSummaryCounts(
      totalCards: cards.length,
      byteDuplicatesCount: byteDuplicateIds.length,
      nameDuplicatesCount: nameDuplicateIds.length,
      similarNamesCount: similarNameIds.length,
      incompleteImagesCount: incompleteImageIds.length,
    );

    return DatasetSearchIndex._(
      scope: scope,
      cards: cards,
      packs: packs,
      topics: topics,
      summaryCounts: summaryCounts,
      matchesById: matchesById,
      tokenIndex: tokenIndex,
      packToCardIds: packToCardIds,
      topicToCardIds: topicToCardIds,
      difficultyToCardIds: difficultyToCardIds,
      stateToCardIds: stateToCardIds,
      incompleteImageCardIds: incompleteImageIds,
      byteDuplicateCardIds: byteDuplicateIds,
      nameDuplicateCardIds: nameDuplicateIds,
      similarNameCardIds: similarNameIds,
    );
  }

  /// Empty index fallback.
  factory DatasetSearchIndex.empty(DatasetScope scope) => DatasetSearchIndex._(
    scope: scope,
    cards: const [],
    packs: const [],
    topics: const [],
    summaryCounts: const SearchSummaryCounts(
      totalCards: 0,
      byteDuplicatesCount: 0,
      nameDuplicatesCount: 0,
      similarNamesCount: 0,
      incompleteImagesCount: 0,
    ),
    matchesById: const {},
    tokenIndex: const {},
    packToCardIds: const {},
    topicToCardIds: const {},
    difficultyToCardIds: const {},
    stateToCardIds: const {},
    incompleteImageCardIds: const {},
    byteDuplicateCardIds: const {},
    nameDuplicateCardIds: const {},
    similarNameCardIds: const {},
  );

  /// Executes a query against the index and returns matching cards,
  /// pagination slices, and matching packs/topics.
  CardSearchResult search(CardSearchQuery query) {
    Set<String>? candidateIds;

    // 1. Text filter via token intersection
    final trimmedQuery = query.text.trim().toLowerCase();
    if (trimmedQuery.isNotEmpty) {
      final queryTokens = _tokenize(trimmedQuery);
      if (queryTokens.isNotEmpty) {
        for (final qToken in queryTokens) {
          final matchingForToken = <String>{};
          for (final entry in _tokenIndex.entries) {
            if (entry.key.contains(qToken)) {
              matchingForToken.addAll(entry.value);
            }
          }
          if (candidateIds == null) {
            candidateIds = matchingForToken;
          } else {
            candidateIds = candidateIds.intersection(matchingForToken);
          }
          if (candidateIds.isEmpty) break;
        }
      }
    }

    // 2. Pack ID filter
    if (query.packId != null) {
      final packCards = _packToCardIds[query.packId] ?? const <String>{};
      candidateIds = candidateIds == null
          ? Set.of(packCards)
          : candidateIds.intersection(packCards);
    }

    // 3. Topic ID filter
    if (query.topicId != null) {
      final topicCards = _topicToCardIds[query.topicId] ?? const <String>{};
      candidateIds = candidateIds == null
          ? Set.of(topicCards)
          : candidateIds.intersection(topicCards);
    }

    // 4. Difficulty filter
    if (query.difficulty != null) {
      final diffCards =
          _difficultyToCardIds[query.difficulty] ?? const <String>{};
      candidateIds = candidateIds == null
          ? Set.of(diffCards)
          : candidateIds.intersection(diffCards);
    }

    // 5. State / Status filter
    if (query.state != null && query.state != 'all') {
      final stateCards = _stateToCardIds[query.state] ?? const <String>{};
      candidateIds = candidateIds == null
          ? Set.of(stateCards)
          : candidateIds.intersection(stateCards);
    }

    // 6. Draft status filter
    if (query.draftStatus != null) {
      final draftCards = <String>{};
      for (final card in cards) {
        if (card.pending?.status == query.draftStatus) {
          draftCards.add(card.id);
        }
      }
      candidateIds = candidateIds == null
          ? draftCards
          : candidateIds.intersection(draftCards);
    }

    // 7. Incomplete image filter
    if (query.incompleteImageOnly) {
      candidateIds = candidateIds == null
          ? Set.of(_incompleteImageCardIds)
          : candidateIds.intersection(_incompleteImageCardIds);
    }

    // 8. Duplicate filter
    if (query.duplicateFilter != DuplicateFilter.all) {
      final dupCards = switch (query.duplicateFilter) {
        DuplicateFilter.all => candidateIds ?? _matchesById.keys.toSet(),
        DuplicateFilter.anyDuplicate => {
          ..._byteDuplicateCardIds,
          ..._nameDuplicateCardIds,
          ..._similarNameCardIds,
        },
        DuplicateFilter.byteDuplicate => _byteDuplicateCardIds,
        DuplicateFilter.nameDuplicate => _nameDuplicateCardIds,
        DuplicateFilter.similarName => _similarNameCardIds,
      };
      candidateIds = candidateIds == null
          ? Set.of(dupCards)
          : candidateIds.intersection(dupCards);
    }

    // Resolve matched cards
    final matchingIds = candidateIds ?? _matchesById.keys.toSet();
    final matchedItems = <CardSearchMatch>[
      for (final id in matchingIds)
        if (_matchesById.containsKey(id)) _matchesById[id]!,
    ];

    // Sort items
    _sortItems(matchedItems, query.sort);

    // Pagination
    final totalMatches = matchedItems.length;
    final pageSize = query.pageSize <= 0 ? 50 : query.pageSize;
    final totalPages = totalMatches == 0 ? 1 : (totalMatches / pageSize).ceil();
    final currentPage = query.page.clamp(1, totalPages);
    final startIndex = (currentPage - 1) * pageSize;
    final endIndex = math.min(startIndex + pageSize, totalMatches);

    final paginatedItems = (startIndex < totalMatches)
        ? matchedItems.sublist(startIndex, endIndex)
        : <CardSearchMatch>[];

    // Find matching packs and topics for global searches
    final matchingPacks = trimmedQuery.isEmpty
        ? const <PackSummary>[]
        : packs
              .where(
                (p) =>
                    p.name.toLowerCase().contains(trimmedQuery) ||
                    p.id.toLowerCase().contains(trimmedQuery),
              )
              .toList();

    final matchingTopics = trimmedQuery.isEmpty
        ? const <TopicTaxonomy>[]
        : topics
              .where(
                (t) =>
                    t.name.toLowerCase().contains(trimmedQuery) ||
                    t.id.toLowerCase().contains(trimmedQuery),
              )
              .toList();

    return CardSearchResult(
      items: paginatedItems,
      totalMatches: totalMatches,
      page: currentPage,
      pageSize: pageSize,
      totalPages: totalPages,
      matchingTopics: matchingTopics,
      matchingPacks: matchingPacks,
      summary: summaryCounts,
    );
  }

  static void _sortItems(List<CardSearchMatch> items, CardSortOption sort) {
    items.sort((a, b) {
      switch (sort) {
        case CardSortOption.nameAsc:
          final cmp = a.card.name.toLowerCase().compareTo(
            b.card.name.toLowerCase(),
          );
          return cmp != 0 ? cmp : a.card.id.compareTo(b.card.id);
        case CardSortOption.nameDesc:
          final cmp = b.card.name.toLowerCase().compareTo(
            a.card.name.toLowerCase(),
          );
          return cmp != 0 ? cmp : b.card.id.compareTo(a.card.id);
        case CardSortOption.difficultyAsc:
          final cmp = a.card.difficulty.compareTo(b.card.difficulty);
          return cmp != 0
              ? cmp
              : a.card.name.toLowerCase().compareTo(b.card.name.toLowerCase());
        case CardSortOption.difficultyDesc:
          final cmp = b.card.difficulty.compareTo(a.card.difficulty);
          return cmp != 0
              ? cmp
              : a.card.name.toLowerCase().compareTo(b.card.name.toLowerCase());
        case CardSortOption.revisionAsc:
          final cmp = a.card.revision.compareTo(b.card.revision);
          return cmp != 0 ? cmp : a.card.id.compareTo(b.card.id);
        case CardSortOption.revisionDesc:
          final cmp = b.card.revision.compareTo(a.card.revision);
          return cmp != 0 ? cmp : a.card.id.compareTo(b.card.id);
        case CardSortOption.status:
          final cmp = a.card.state.compareTo(b.card.state);
          return cmp != 0
              ? cmp
              : a.card.name.toLowerCase().compareTo(b.card.name.toLowerCase());
        case CardSortOption.duplicatesFirst:
          if (a.hasAnyDuplicate != b.hasAnyDuplicate) {
            return a.hasAnyDuplicate ? -1 : 1;
          }
          return a.card.name.toLowerCase().compareTo(b.card.name.toLowerCase());
      }
    });
  }

  static String? _extractImageHash(CardSummary card) {
    if (card.localImage?.preparation?.sha256 != null) {
      return card.localImage!.preparation!.sha256;
    }
    if (card.pending?.uploadedImage?.sha256 != null) {
      return card.pending!.uploadedImage!.sha256;
    }
    final ref = card.imageReference;
    if (ref == null || ref.trim().isEmpty) return null;
    if (ref.startsWith('objects/') && ref.length >= 72) {
      // 'objects/' is 8 chars, 64-char sha256
      return ref.substring(8, 72);
    }
    return ref;
  }

  static String _normalize(String input) {
    return input.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  static List<String> _tokenize(String input) {
    final normalized = _normalize(input);
    if (normalized.isEmpty) return const [];
    // Split by non-alphanumeric unicode characters
    return normalized
        .split(RegExp(r'[^a-z0-9\u00C0-\u024F\u1E00-\u1EFF]+'))
        .where((t) => t.isNotEmpty)
        .toList();
  }

  static bool _areSimilarNamesMeta(_CardNameMeta a, _CardNameMeta b) {
    if (a.normalized.isEmpty || b.normalized.isEmpty) return false;
    if (a.normalized == b.normalized) return true;

    final lenA = a.normalized.length;
    final lenB = b.normalized.length;
    final lenDiff = (lenA - lenB).abs();

    if (lenDiff > 2) {
      // Must have token overlap to be similar; if no shared tokens, cannot be similar
      var hasOverlap = false;
      for (final t in a.tokens) {
        if (b.tokens.contains(t)) {
          hasOverlap = true;
          break;
        }
      }
      if (!hasOverlap) return false;
    }

    // Token containment (e.g. "luffy" in "monkey d luffy")
    final tokensA = a.tokens;
    final tokensB = b.tokens;
    if (tokensA.isNotEmpty && tokensB.isNotEmpty) {
      if (tokensA.containsAll(tokensB) || tokensB.containsAll(tokensA)) {
        return true;
      }
      final intersection = tokensA.intersection(tokensB).length;
      if (intersection > 0) {
        final union = tokensA.union(tokensB).length;
        if (union > 0 && (intersection / union) >= 0.5) {
          return true;
        }
      }
    }

    // Levenshtein distance <= 2 for strings of reasonable length
    if (lenA >= 4 && lenB >= 4 && lenDiff <= 2) {
      if (_isLevenshteinAtMost2(a.normalized, b.normalized)) {
        return true;
      }
    }

    return false;
  }

  static bool _isLevenshteinAtMost2(String s, String t) {
    final m = s.length;
    final n = t.length;
    if ((m - n).abs() > 2) return false;
    if (s == t) return true;

    // Common prefix
    var start = 0;
    while (start < m &&
        start < n &&
        s.codeUnitAt(start) == t.codeUnitAt(start)) {
      start++;
    }
    // Common suffix
    var endS = m - 1;
    var endT = n - 1;
    while (endS >= start &&
        endT >= start &&
        s.codeUnitAt(endS) == t.codeUnitAt(endT)) {
      endS--;
      endT--;
    }

    final remS = endS - start + 1;
    final remT = endT - start + 1;
    if (remS <= 2 && remT <= 2) {
      if (remS == 0) return remT <= 2;
      if (remT == 0) return remS <= 2;
      if (remS == 1 && remT == 1) return true;
      if (remS == 1 && remT == 2) return true;
      if (remS == 2 && remT == 1) return true;
      if (remS == 2 && remT == 2) {
        var mismatches = 0;
        for (var i = 0; i < 2; i++) {
          if (s.codeUnitAt(start + i) != t.codeUnitAt(start + i)) mismatches++;
        }
        return mismatches <= 2;
      }
    }
    return false;
  }
}

class _CardNameMeta {
  _CardNameMeta(this.card)
    : normalized = DatasetSearchIndex._normalize(card.name),
      tokens = DatasetSearchIndex._tokenize(card.name).toSet();
  final CardSummary card;
  final String normalized;
  final Set<String> tokens;
}
