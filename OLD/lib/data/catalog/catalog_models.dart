import '../../domain/models/content_validation.dart';

/// Public summaries only. These objects never contain Cards or creator metadata.
final class CatalogTopicSummary {
  const CatalogTopicSummary({
    required this.id,
    required this.name,
    required this.revision,
    this.available = true,
  });
  final String id, name;
  final int revision;
  final bool available;
  factory CatalogTopicSummary.fromPublic(Map<String, dynamic> json) {
    catalogKeys(json, {'id', 'name', 'revision'});
    return CatalogTopicSummary(
      id: catalogId(json['id']),
      name: catalogName(json['name']),
      revision: catalogRevision(json['revision']),
    );
  }
  CatalogTopicSummary withAvailability(bool value) => CatalogTopicSummary(
    id: id,
    name: name,
    revision: revision,
    available: value,
  );
  Map<String, Object?> toPublicJson() => {
    'id': id,
    'name': name,
    'revision': revision,
  };
}

final class CatalogPackSummary {
  const CatalogPackSummary({
    required this.id,
    required this.topicId,
    required this.name,
    required this.revision,
    required this.cardCount,
    required this.manifestSha256,
    this.available = true,
  });
  final String id, topicId, name, manifestSha256;
  final int revision, cardCount;
  final bool available;
  factory CatalogPackSummary.fromPublic(Map<String, dynamic> json) {
    catalogKeys(json, {
      'id',
      'topicId',
      'name',
      'revision',
      'cardCount',
      'manifestSha256',
    });
    if (json['cardCount'] is! int ||
        (json['cardCount'] as int) < 0 ||
        (json['cardCount'] as int) > 9007199254740991 ||
        json['manifestSha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(json['manifestSha256'] as String)) {
      throw const FormatException('Invalid public Pack summary');
    }
    return CatalogPackSummary(
      id: catalogId(json['id']),
      topicId: catalogId(json['topicId']),
      name: catalogName(json['name']),
      revision: catalogRevision(json['revision']),
      cardCount: json['cardCount'] as int,
      manifestSha256: json['manifestSha256'] as String,
    );
  }
  CatalogPackSummary withAvailability(bool value) => CatalogPackSummary(
    id: id,
    topicId: topicId,
    name: name,
    revision: revision,
    cardCount: cardCount,
    manifestSha256: manifestSha256,
    available: value,
  );
  Map<String, Object?> toPublicJson() => {
    'id': id,
    'topicId': topicId,
    'name': name,
    'revision': revision,
    'cardCount': cardCount,
    'manifestSha256': manifestSha256,
  };
}

final class CatalogSnapshot {
  CatalogSnapshot({
    required this.origin,
    required List<CatalogTopicSummary> topics,
    required List<CatalogPackSummary> packs,
    this.topicsCheckedAt,
    Map<String, DateTime> packsCheckedAt = const {},
    this.topicsEtag,
    Map<String, String> packsEtags = const {},
  }) : topics = List.unmodifiable(topics),
       packs = List.unmodifiable(packs),
       packsCheckedAt = Map.unmodifiable(packsCheckedAt),
       packsEtags = Map.unmodifiable(packsEtags);
  final String origin;
  final List<CatalogTopicSummary> topics;
  final List<CatalogPackSummary> packs;
  final DateTime? topicsCheckedAt;
  final Map<String, DateTime> packsCheckedAt;

  /// Validators exist only for fully cached single-page scopes.
  final String? topicsEtag;
  final Map<String, String> packsEtags;
  factory CatalogSnapshot.empty(String origin) =>
      CatalogSnapshot(origin: origin, topics: const [], packs: const []);
  List<CatalogPackSummary> packsForTopic(String id) =>
      List.unmodifiable(packs.where((p) => p.topicId == id));
  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'protocolVersion': 1,
    'origin': origin,
    'topics': [
      for (final topic in topics)
        {...topic.toPublicJson(), 'available': topic.available},
    ],
    'packs': [
      for (final pack in packs)
        {...pack.toPublicJson(), 'available': pack.available},
    ],
    'topicsCheckedAt': topicsCheckedAt?.toUtc().toIso8601String(),
    'packsCheckedAt': {
      for (final entry in packsCheckedAt.entries)
        entry.key: entry.value.toUtc().toIso8601String(),
    },
    'topicsEtag': topicsEtag,
    'packsEtags': packsEtags,
  };
  factory CatalogSnapshot.fromJson(Map<String, dynamic> json, String origin) {
    catalogKeys(json, {
      'schemaVersion',
      'protocolVersion',
      'origin',
      'topics',
      'packs',
      'topicsCheckedAt',
      'packsCheckedAt',
      'topicsEtag',
      'packsEtags',
    });
    if (json['schemaVersion'] != 1 ||
        json['protocolVersion'] != 1 ||
        json['origin'] != origin ||
        json['topics'] is! List ||
        json['packs'] is! List) {
      throw const FormatException('Incompatible public catalog cache');
    }
    final topics = <CatalogTopicSummary>[];
    for (final raw in json['topics'] as List) {
      final row = catalogObject(raw);
      if (row['available'] is! bool) {
        throw const FormatException('Invalid cached availability');
      }
      final available = row.remove('available') as bool;
      topics.add(
        CatalogTopicSummary.fromPublic(row).withAvailability(available),
      );
    }
    final packs = <CatalogPackSummary>[];
    for (final raw in json['packs'] as List) {
      final row = catalogObject(raw);
      if (row['available'] is! bool) {
        throw const FormatException('Invalid cached availability');
      }
      final available = row.remove('available') as bool;
      packs.add(CatalogPackSummary.fromPublic(row).withAvailability(available));
    }
    final ids = topics.map((t) => t.id).toSet();
    if (topics.length > 10000 ||
        packs.length > 50000 ||
        ids.length != topics.length ||
        packs.map((p) => p.id).toSet().length != packs.length ||
        packs.any((p) => !ids.contains(p.topicId))) {
      throw const FormatException('Incomplete public catalog cache');
    }
    final checked = {
      for (final entry in catalogObject(json['packsCheckedAt']).entries)
        entry.key: catalogDate(entry.value),
    };
    final etags = {
      for (final entry in catalogObject(json['packsEtags']).entries)
        entry.key: catalogEtag(entry.value),
    };
    if (checked.keys.any((id) => !ids.contains(id)) ||
        etags.keys.any((id) => !checked.containsKey(id)) ||
        packs.any((pack) => !checked.containsKey(pack.topicId))) {
      throw const FormatException('Invalid cached scopes');
    }
    final topicsChecked = json['topicsCheckedAt'] == null
        ? null
        : catalogDate(json['topicsCheckedAt']);
    if (topics.isNotEmpty && topicsChecked == null ||
        json['topicsEtag'] != null && topicsChecked == null) {
      throw const FormatException('Missing completed catalog scan');
    }
    return CatalogSnapshot(
      origin: origin,
      topics: topics,
      packs: packs,
      topicsCheckedAt: topicsChecked,
      packsCheckedAt: checked,
      topicsEtag: json['topicsEtag'] == null
          ? null
          : catalogEtag(json['topicsEtag']),
      packsEtags: etags,
    );
  }
}

Map<String, dynamic> catalogObject(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw const FormatException('Expected public object');
  }
  return Map<String, dynamic>.from(value);
}

void catalogKeys(Map<String, dynamic> value, Set<String> keys) {
  if (value.length != keys.length ||
      value.keys.any((key) => !keys.contains(key))) {
    throw const FormatException('Unexpected public catalog fields');
  }
}

String catalogId(Object? value) {
  if (value is! String || value.length > 4096) {
    throw const FormatException('Invalid public ID');
  }
  try {
    return ContentValidation.id(value, 'id');
  } on ArgumentError {
    throw const FormatException('Invalid public ID');
  }
}

String catalogName(Object? value) {
  if (value is! String || value.length > 4096) {
    throw const FormatException('Invalid public name');
  }
  try {
    return ContentValidation.text(value, 'name');
  } on ArgumentError {
    throw const FormatException('Invalid public name');
  }
}

int catalogRevision(Object? value) {
  if (value is! int || value < 1 || value > 9007199254740991) {
    throw const FormatException('Invalid public revision');
  }
  return value;
}

String catalogEtag(Object? value) {
  if (value is! String || !RegExp(r'^"[a-f0-9]{64}"$').hasMatch(value)) {
    throw const FormatException('Invalid catalog validator');
  }
  return value;
}

DateTime catalogDate(Object? value) {
  if (value is! String) {
    throw const FormatException('Invalid catalog timestamp');
  }
  return DateTime.parse(value).toUtc();
}
