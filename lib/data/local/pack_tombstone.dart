import '../../domain/models/content_validation.dart';

/// Distinct from quota and validation failures, including racing writers.
final class PackDeletedException extends StateError {
  PackDeletedException() : super('Pack was authoritatively deleted');
}

/// Validated deletion evidence from one configured public origin. Its local
/// origin binding is never accepted from the anonymous wire response itself.
final class PackTombstone {
  PackTombstone({
    required String packId,
    required int revision,
    required DateTime deletedAt,
    String reason = 'administrative_deletion',
    required String sourceOrigin,
  }) : packId = ContentValidation.id(packId, 'packId'),
       revision = ContentValidation.revision(revision),
       deletedAt = _utc(deletedAt),
       reason = _reason(reason),
       sourceOrigin = _origin(sourceOrigin) {
    if (revision > 9007199254740991) {
      throw const FormatException('Unsafe tombstone revision');
    }
  }

  final String packId, reason, sourceOrigin;
  final int revision;
  final DateTime deletedAt;

  factory PackTombstone.fromWire(
    Map<String, dynamic> json, {
    required String sourceOrigin,
  }) {
    _keys(json, {'packId', 'revision', 'deletedAt', 'reason'});
    if (json['packId'] is! String ||
        json['revision'] is! int ||
        json['deletedAt'] is! String ||
        json['reason'] is! String) {
      throw const FormatException('Invalid tombstone fields');
    }
    return PackTombstone(
      packId: json['packId'] as String,
      revision: json['revision'] as int,
      deletedAt: parseDeletedAt(json['deletedAt'] as String),
      reason: json['reason'] as String,
      sourceOrigin: sourceOrigin,
    );
  }

  factory PackTombstone.fromJson(Map<String, dynamic> json) {
    _keys(json, {'packId', 'revision', 'deletedAt', 'reason', 'sourceOrigin'});
    if (json['sourceOrigin'] is! String) {
      throw const FormatException('Invalid tombstone origin');
    }
    return PackTombstone.fromWire({
      for (final entry in json.entries)
        if (entry.key != 'sourceOrigin') entry.key: entry.value,
    }, sourceOrigin: json['sourceOrigin'] as String);
  }

  Map<String, dynamic> toJson() => {
    'packId': packId,
    'revision': revision,
    'deletedAt': deletedAt.toIso8601String(),
    'reason': reason,
    'sourceOrigin': sourceOrigin,
  };

  static DateTime parseDeletedAt(String value) {
    final match = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?Z$',
    ).firstMatch(value);
    final parsed = DateTime.tryParse(value);
    if (match == null ||
        parsed == null ||
        !parsed.isUtc ||
        parsed.year != int.parse(match[1]!) ||
        parsed.month != int.parse(match[2]!) ||
        parsed.day != int.parse(match[3]!) ||
        parsed.hour != int.parse(match[4]!) ||
        parsed.minute != int.parse(match[5]!) ||
        parsed.second != int.parse(match[6]!)) {
      throw const FormatException('Invalid UTC tombstone timestamp');
    }
    return parsed;
  }
}

DateTime _utc(DateTime value) {
  if (!value.isUtc) throw const FormatException('Tombstone time must be UTC');
  return value;
}

String _reason(String value) {
  if (value != 'administrative_deletion') {
    throw const FormatException('Invalid tombstone reason');
  }
  return value;
}

String _origin(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      !{'', '/'}.contains(uri.path) ||
      !(uri.scheme == 'https' ||
          uri.scheme == 'http' &&
              {'localhost', '127.0.0.1', '::1'}.contains(uri.host))) {
    throw const FormatException('Invalid public tombstone origin');
  }
  return uri.origin;
}

void _keys(Map<String, dynamic> json, Set<String> keys) {
  if (json.length != keys.length || !keys.containsAll(json.keys)) {
    throw const FormatException('Invalid tombstone fields');
  }
}

/// Durable local management metadata. A null tombstone is a reversible user
/// removal; deletion evidence is retained even after private bytes are reclaimed.
final class PackRetirement {
  PackRetirement({
    required String packId,
    required String name,
    required String topicId,
    required int installedRevision,
    required String manifestSha256,
    required DateTime removedAt,
    required this.publicSyncEligible,
    this.tombstone,
  }) : packId = ContentValidation.id(packId, 'packId'),
       name = ContentValidation.text(name, 'name'),
       topicId = ContentValidation.id(topicId, 'topicId'),
       installedRevision = ContentValidation.revision(installedRevision),
       manifestSha256 = _sha(manifestSha256),
       removedAt = _utc(removedAt) {
    if (tombstone != null &&
        (tombstone!.packId != packId ||
            tombstone!.revision <= installedRevision)) {
      throw const FormatException('Invalid retirement evidence');
    }
  }
  final String packId, name, topicId, manifestSha256;
  final int installedRevision;
  final bool publicSyncEligible;
  final DateTime removedAt;
  final PackTombstone? tombstone;
  bool get isAuthoritative => tombstone != null;
  Map<String, dynamic> toJson() => {
    'packId': packId,
    'name': name,
    'topicId': topicId,
    'installedRevision': installedRevision,
    'manifestSha256': manifestSha256,
    'removedAt': removedAt.toIso8601String(),
    'publicSyncEligible': publicSyncEligible,
    'tombstone': tombstone?.toJson(),
  };
  factory PackRetirement.fromJson(Map<String, dynamic> json) {
    _keys(json, {
      'packId',
      'name',
      'topicId',
      'installedRevision',
      'manifestSha256',
      'removedAt',
      'publicSyncEligible',
      'tombstone',
    });
    if (json['packId'] is! String ||
        json['name'] is! String ||
        json['topicId'] is! String ||
        json['installedRevision'] is! int ||
        json['manifestSha256'] is! String ||
        json['removedAt'] is! String ||
        json['publicSyncEligible'] is! bool ||
        json['tombstone'] != null &&
            json['tombstone'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid retirement metadata');
    }
    return PackRetirement(
      packId: json['packId'] as String,
      name: json['name'] as String,
      topicId: json['topicId'] as String,
      installedRevision: json['installedRevision'] as int,
      manifestSha256: json['manifestSha256'] as String,
      removedAt: PackTombstone.parseDeletedAt(json['removedAt'] as String),
      publicSyncEligible: json['publicSyncEligible'] as bool,
      tombstone: json['tombstone'] == null
          ? null
          : PackTombstone.fromJson(json['tombstone'] as Map<String, dynamic>),
    );
  }
}

String _sha(String value) {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw const FormatException('Invalid manifest digest');
  }
  return value;
}
