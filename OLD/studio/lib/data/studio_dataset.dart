import 'dart:convert';

import 'card_image.dart';
import 'image_ingestion.dart';

/// Namespace is a routing key, never a persisted authorization credential.
class DatasetScope {
  const DatasetScope(this.project, this.uid, this.role);
  final String project;
  final String uid;
  final String role;
  static const protocolVersion = 1;
  static const scopeVersion = 1;
  String get accountKey => jsonEncode([project, uid]);
  String get namespace =>
      jsonEncode([protocolVersion, scopeVersion, project, uid, role]);
  Map<String, Object?> toJson() => {
    'project': project,
    'uid': uid,
    'role': role,
  };
  factory DatasetScope.fromJson(Map<String, Object?> json) {
    if (json.keys.toSet().difference({'project', 'uid', 'role'}).isNotEmpty ||
        json['project'] is! String ||
        (json['project'] as String).isEmpty ||
        json['uid'] is! String ||
        (json['uid'] as String).isEmpty ||
        !{'owner_admin', 'collector'}.contains(json['role'])) {
      throw const FormatException('Invalid dataset scope');
    }
    return DatasetScope(
      json['project']! as String,
      json['uid']! as String,
      json['role']! as String,
    );
  }
}

enum DraftStatus { draft, unsent, conflict }

/// Pending content only. Tokens, role claims and credentials never belong here.
class LocalDraft {
  LocalDraft({
    required this.id,
    required this.resourceType,
    required this.resourceId,
    required Map<String, Object?> value,
    this.baseRevision,
    this.action = 'update',
    this.status = DraftStatus.draft,
    this.publishedRevision,
    this.localImage,
    this.uploadedImage,
  }) : value = Map.unmodifiable(value);
  final String id;
  final String resourceType;
  final String resourceId;
  final int? baseRevision;
  final String action;
  final Map<String, Object?> value;
  final DraftStatus status;
  final int? publishedRevision;
  final CardImage? localImage;
  final UploadedCardImage? uploadedImage;

  LocalDraft copyWith({
    Map<String, Object?>? value,
    DraftStatus? status,
    int? publishedRevision,
    CardImage? localImage,
    bool clearLocalImage = false,
    UploadedCardImage? uploadedImage,
    bool clearUploadedImage = false,
  }) => LocalDraft(
    id: id,
    resourceType: resourceType,
    resourceId: resourceId,
    baseRevision: baseRevision,
    action: action,
    value: value ?? this.value,
    status: status ?? this.status,
    publishedRevision: publishedRevision ?? this.publishedRevision,
    localImage: clearLocalImage ? null : localImage ?? this.localImage,
    uploadedImage: clearUploadedImage
        ? null
        : uploadedImage ?? this.uploadedImage,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'resourceType': resourceType,
    'resourceId': resourceId,
    'baseRevision': baseRevision,
    'action': action,
    'value': value,
    'status': status.name,
    'publishedRevision': publishedRevision,
    if (localImage != null) 'localImage': localImage!.toJson(),
    if (uploadedImage != null) 'uploadedImage': uploadedImage!.toJson(),
  };
  factory LocalDraft.fromJson(Map<String, Object?> json) {
    if (!_keys(json, {
          'id',
          'resourceType',
          'resourceId',
          'baseRevision',
          'action',
          'value',
          'status',
          'publishedRevision',
          'localImage',
          'uploadedImage',
        }) ||
        json['id'] is! String ||
        (json['id'] as String).isEmpty ||
        !{'topic', 'pack', 'card'}.contains(json['resourceType']) ||
        json['resourceId'] is! String ||
        (json['resourceId'] as String).isEmpty ||
        json['value'] is! Map ||
        !DraftStatus.values.any((state) => state.name == json['status']) ||
        (json['action'] != null &&
            !{
              'create',
              'update',
              'hide',
              'softDelete',
              'restore',
              'permanentDelete',
            }.contains(json['action'])) ||
        (json['localImage'] != null &&
            (json['resourceType'] != 'card' ||
                !{'create', 'update'}.contains(json['action'] ?? 'update') ||
                json['localImage'] is! Map)) ||
        (json['uploadedImage'] != null &&
            (json['resourceType'] != 'card' ||
                json['localImage'] == null ||
                json['uploadedImage'] is! Map)) ||
        !_revision(json['baseRevision']) ||
        !_revision(json['publishedRevision'])) {
      throw const FormatException('Invalid local draft');
    }
    return LocalDraft(
      id: json['id']! as String,
      resourceType: json['resourceType']! as String,
      resourceId: json['resourceId']! as String,
      value: _map(json['value']),
      baseRevision: json['baseRevision'] as int?,
      action: json['action'] as String? ?? 'update',
      status: DraftStatus.values.byName(json['status']! as String),
      publishedRevision: json['publishedRevision'] as int?,
      localImage: json['localImage'] == null
          ? null
          : CardImage.fromJson(_map(json['localImage'])),
      uploadedImage: json['uploadedImage'] == null
          ? null
          : UploadedCardImage.fromJson(_map(json['uploadedImage'])),
    );
  }
}

class DatasetSnapshot {
  DatasetSnapshot({
    required this.scope,
    required List<Map<String, Object?>> records,
    List<LocalDraft> drafts = const [],
    this.resumeCursor,
    this.lastSyncedAt,
    this.version = 0,
    this.pendingCommit,
    this.lastCommittedAt,
  }) : records = List.unmodifiable(
         records.map((record) => Map<String, Object?>.unmodifiable(record)),
       ),
       drafts = List.unmodifiable(drafts);
  final DatasetScope scope;
  final List<Map<String, Object?>> records;
  final List<LocalDraft> drafts;
  final String? resumeCursor;
  final DateTime? lastSyncedAt;
  final int version;
  final Map<String, Object?>? pendingCommit;
  final DateTime? lastCommittedAt;

  DatasetSnapshot copyWith({
    List<Map<String, Object?>>? records,
    List<LocalDraft>? drafts,
    String? resumeCursor,
    DateTime? lastSyncedAt,
    int? version,
    Map<String, Object?>? pendingCommit,
    bool clearPendingCommit = false,
    DateTime? lastCommittedAt,
  }) => DatasetSnapshot(
    scope: scope,
    records: records ?? this.records,
    drafts: drafts ?? this.drafts,
    resumeCursor: resumeCursor ?? this.resumeCursor,
    lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
    version: version ?? this.version,
    pendingCommit: clearPendingCommit
        ? null
        : pendingCommit ?? this.pendingCommit,
    lastCommittedAt: lastCommittedAt ?? this.lastCommittedAt,
  );
  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'scope': scope.toJson(),
    'records': records,
    'drafts': drafts.map((draft) => draft.toJson()).toList(),
    'resumeCursor': resumeCursor,
    'lastSyncedAt': lastSyncedAt?.toUtc().toIso8601String(),
    'version': version,
    if (pendingCommit != null) 'pendingCommit': pendingCommit,
    if (lastCommittedAt != null)
      'lastCommittedAt': lastCommittedAt!.toUtc().toIso8601String(),
  };
  factory DatasetSnapshot.fromJson(Map<String, Object?> json) {
    if (!_keys(json, {
          'schemaVersion',
          'scope',
          'records',
          'drafts',
          'resumeCursor',
          'lastSyncedAt',
          'version',
          'pendingCommit',
          'lastCommittedAt',
        }) ||
        json['schemaVersion'] != 1 ||
        json['scope'] is! Map ||
        json['records'] is! List ||
        json['drafts'] is! List ||
        (json['resumeCursor'] != null && json['resumeCursor'] is! String) ||
        (json['lastSyncedAt'] != null && json['lastSyncedAt'] is! String) ||
        json['version'] is! int ||
        (json['version'] as int) < 0) {
      throw const FormatException('Unsupported or invalid dataset');
    }
    return DatasetSnapshot(
      scope: DatasetScope.fromJson(_map(json['scope'])),
      records: (json['records']! as List).map(_map).toList(),
      drafts: (json['drafts']! as List)
          .map((v) => LocalDraft.fromJson(_map(v)))
          .toList(),
      resumeCursor: json['resumeCursor'] as String?,
      lastSyncedAt: json['lastSyncedAt'] == null
          ? null
          : DateTime.parse(json['lastSyncedAt']! as String),
      version: json['version']! as int,
      pendingCommit: json['pendingCommit'] == null
          ? null
          : _commitIntent(json['pendingCommit']),
      lastCommittedAt: json['lastCommittedAt'] == null
          ? null
          : DateTime.parse(json['lastCommittedAt']! as String),
    );
  }
}

bool _revision(Object? value) => value == null || value is int && value >= 0;
Map<String, Object?> _map(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw const FormatException('Expected content object');
  }
  return Map<String, Object?>.from(value);
}

bool _keys(Map<String, Object?> json, Set<String> keys) =>
    json.keys.every(keys.contains);

Map<String, Object?> _commitIntent(Object? value) {
  final intent = _map(value);
  if (intent.length != 4 ||
      !_keys(intent, {'key', 'draftId', 'revision', 'batch'}) ||
      intent['key'] is! String ||
      (intent['key'] as String).isEmpty ||
      intent['draftId'] is! String ||
      (intent['draftId'] as String).isEmpty ||
      intent['revision'] is! int ||
      (intent['revision'] as int) < 0) {
    throw const FormatException('Invalid pending Commit');
  }
  final batch = _map(intent['batch']);
  final aggregate = _map(batch['aggregate']);
  if (batch.length != 3 ||
      !_keys(batch, {'protocolVersion', 'aggregate', 'operations'}) ||
      batch['protocolVersion'] != 1 ||
      aggregate.length != 2 ||
      !_keys(aggregate, {'resourceType', 'id'}) ||
      !{'topic', 'pack'}.contains(aggregate['resourceType']) ||
      aggregate['id'] is! String ||
      batch['operations'] is! List ||
      (batch['operations'] as List).length != 1) {
    throw const FormatException('Invalid pending batch');
  }
  final op = _map((batch['operations'] as List).single);
  if (!_keys(op, {'resourceType', 'id', 'action', 'value'}) ||
      !{'topic', 'pack', 'card'}.contains(op['resourceType']) ||
      op['id'] is! String ||
      !{
        'create',
        'update',
        'hide',
        'softDelete',
        'restore',
        'permanentDelete',
      }.contains(op['action'])) {
    throw const FormatException('Invalid pending operation');
  }
  if ({'create', 'update'}.contains(op['action'])) {
    final fields = switch (op['resourceType']) {
      'topic' => {'name'},
      'pack' => {'name', 'topicId'},
      _ => {'name', 'packId', 'difficulty', 'imageReference'},
    };
    final content = _map(op['value']);
    if (content.length != fields.length || !_keys(content, fields)) {
      throw const FormatException('Invalid pending value');
    }
  } else if (op.containsKey('value')) {
    throw const FormatException('Unexpected pending value');
  }
  return intent;
}
