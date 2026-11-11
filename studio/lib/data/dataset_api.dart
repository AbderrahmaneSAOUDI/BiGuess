import 'dart:convert';

import 'package:http/http.dart' as http;

class DatasetApiFailure implements Exception {
  const DatasetApiFailure(this.code);
  final String code;
}

class InitialDataset {
  const InitialDataset(this.records, this.resumeCursor);
  final List<Map<String, Object?>> records;
  final String resumeCursor;
}

class BatchCommitResult {
  const BatchCommitResult({
    required this.revision,
    required this.committedAt,
    required this.actorId,
  });
  final int revision;
  final String committedAt;
  final String actorId;
}

abstract interface class DatasetApi {
  Future<InitialDataset> initial(String token, bool Function() current);
  Future<BatchCommitResult> commitBatch(
    String token, {
    required String idempotencyKey,
    required int revision,
    required Map<String, Object?> batch,
    required bool Function() current,
  });
  void close();
}

abstract interface class IncrementalDatasetApi {
  Future<InitialDataset> changes(
    String token,
    List<Map<String, Object?>> records,
    String cursor,
    bool Function() current, {
    bool owner = false,
  });
}

/// All pages stage in memory; callers promote only a complete, validated scan.
class WorkerDatasetApi implements DatasetApi, IncrementalDatasetApi {
  WorkerDatasetApi(this.base, this.client);
  final Uri base;
  final http.Client client;

  @override
  Future<InitialDataset> changes(
    String token,
    List<Map<String, Object?>> records,
    String cursor,
    bool Function() current, {
    bool owner = false,
  }) async {
    try {
      return await _changes(token, records, cursor, current, owner);
    } on DatasetApiFailure catch (error) {
      // An expired or changed scope cursor cannot be repaired locally. Stage a
      // fresh authorized snapshot, retaining the caller's last good dataset.
      if (error.code != 'cursor_expired') rethrow;
      return initial(token, current);
    }
  }

  Future<InitialDataset> _changes(
    String token,
    List<Map<String, Object?>> records,
    String cursor,
    bool Function() current,
    bool owner,
  ) async {
    String key(Map<String, Object?> record) =>
        jsonEncode([record['resourceType'], record['id']]);
    final staged = {for (final record in records) key(record): record};
    final revisions = {
      for (final record in records) key(record): record['revision']! as int,
    };
    final cursors = {cursor};
    while (true) {
      if (!current()) throw const DatasetApiFailure('cancelled');
      final uri = base
          .resolve('/studio/v1/sync/changes')
          .replace(queryParameters: {'limit': '100', 'cursor': cursor});
      final response = await client
          .get(uri, headers: {'Authorization': 'Bearer $token'})
          .timeout(const Duration(seconds: 20));
      if (!current()) throw const DatasetApiFailure('cancelled');
      if (response.statusCode == 401) {
        throw const DatasetApiFailure('session-expired');
      }
      if (response.statusCode == 403) {
        throw const DatasetApiFailure('forbidden');
      }
      if (response.statusCode == 409) {
        throw const DatasetApiFailure('cursor_expired');
      }
      if (response.statusCode != 200) {
        throw const DatasetApiFailure('sync-unavailable');
      }
      try {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        if (body['protocolVersion'] != 1 ||
            body['scopeVersion'] != 1 ||
            body['items'] is! List ||
            !(body['nextCursor'] == null || body['nextCursor'] is String) ||
            !(body['resumeCursor'] == null || body['resumeCursor'] is String)) {
          throw const FormatException();
        }
        for (final item in body['items'] as List) {
          final event = Map<String, Object?>.from(item as Map);
          final Map<String, Object?> record;
          if (event['kind'] == 'upsert' &&
              event.length == 2 &&
              event['record'] is Map) {
            record = Map<String, Object?>.from(event['record'] as Map);
            validateDatasetRecord(record);
          } else if (event['kind'] == 'remove' &&
              event.length == 4 &&
              {'topic', 'pack', 'card'}.contains(event['resourceType']) &&
              event['id'] is String &&
              (event['id'] as String).isNotEmpty &&
              event['revision'] is int &&
              (event['revision'] as int) > 0) {
            record = event;
          } else {
            throw const FormatException();
          }
          if (owner && event['kind'] == 'remove') {
            // The feed's minimal tombstones omit lifecycle fields that Owner
            // needs for restore/purge review. Rebuild that complete view rather
            // than dropping deleted records from the administrative workspace.
            throw const DatasetApiFailure('cursor_expired');
          }
          final id = key(record);
          final revision = record['revision']! as int;
          // A locally acknowledged Commit may already be ahead of older feed
          // events. Retain its newer projection until the feed catches up.
          if (revision < (revisions[id] ?? 0)) continue;
          revisions[id] = revision;
          if (event['kind'] == 'remove') {
            staged.remove(id);
          } else {
            staged[id] = Map.unmodifiable(record);
          }
        }
        final next = body['nextCursor'] as String?;
        final resume = body['resumeCursor'] as String?;
        if (next == null) {
          if (resume == null || resume.isEmpty) throw const FormatException();
          final result = staged.values.toList(growable: false);
          validateDatasetRelationships(result);
          return InitialDataset(List.unmodifiable(result), resume);
        }
        if (next.isEmpty || resume != null || !cursors.add(next)) {
          throw const FormatException();
        }
        cursor = next;
      } on FormatException {
        throw const DatasetApiFailure('invalid-dataset');
      } on TypeError {
        throw const DatasetApiFailure('invalid-dataset');
      }
    }
  }

  @override
  Future<InitialDataset> initial(String token, bool Function() current) async {
    // A scoped view may change during paging. One bounded restart is safe;
    // network/storage errors are explicit retries, never background polling.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _scan(token, current);
      } on DatasetApiFailure catch (error) {
        if (error.code != 'cursor_expired' || attempt != 0) rethrow;
      }
    }
    throw const DatasetApiFailure('cursor_expired');
  }

  Future<InitialDataset> _scan(String token, bool Function() current) async {
    final records = <Map<String, Object?>>[];
    final ids = <String>{};
    final cursors = <String>{};
    String? cursor;
    while (true) {
      if (!current()) throw const DatasetApiFailure('cancelled');
      final uri = base
          .resolve('/studio/v1/sync/initial')
          .replace(queryParameters: {'limit': '100', 'cursor': ?cursor});
      final response = await client
          .get(uri, headers: {'Authorization': 'Bearer $token'})
          .timeout(const Duration(seconds: 20));
      if (!current()) throw const DatasetApiFailure('cancelled');
      if (response.statusCode == 401) {
        throw const DatasetApiFailure('session-expired');
      }
      if (response.statusCode == 403) {
        throw const DatasetApiFailure('forbidden');
      }
      if (response.statusCode == 409) {
        throw const DatasetApiFailure('cursor_expired');
      }
      if (response.statusCode != 200) {
        throw const DatasetApiFailure('sync-unavailable');
      }
      try {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        if (body['protocolVersion'] != 1 ||
            body['scopeVersion'] != 1 ||
            body['items'] is! List ||
            !(body['nextCursor'] == null || body['nextCursor'] is String) ||
            !(body['resumeCursor'] == null || body['resumeCursor'] is String)) {
          throw const FormatException();
        }
        for (final item in body['items'] as List) {
          final record = Map<String, Object?>.from(item as Map);
          validateDatasetRecord(record);
          final key = jsonEncode([record['resourceType'], record['id']]);
          if (!ids.add(key)) throw const FormatException();
          records.add(Map.unmodifiable(record));
        }
        final next = body['nextCursor'] as String?;
        final resume = body['resumeCursor'] as String?;
        if (next == null) {
          if (resume == null || resume.isEmpty) throw const FormatException();
          validateDatasetRelationships(records);
          return InitialDataset(List.unmodifiable(records), resume);
        }
        if (next.isEmpty || resume != null || !cursors.add(next)) {
          throw const FormatException();
        }
        cursor = next;
      } on FormatException {
        throw const DatasetApiFailure('invalid-dataset');
      } on TypeError {
        throw const DatasetApiFailure('invalid-dataset');
      }
    }
  }

  @override
  Future<BatchCommitResult> commitBatch(
    String token, {
    required String idempotencyKey,
    required int revision,
    required Map<String, Object?> batch,
    required bool Function() current,
  }) async {
    if (!current()) throw const DatasetApiFailure('cancelled');
    final uri = base.resolve('/studio/v1/batches');
    final body = jsonEncode(batch);
    if (utf8.encode(body).length > 262144) {
      throw const DatasetApiFailure('batch-too-large');
    }
    final response = await client
        .post(
          uri,
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
            'Idempotency-Key': idempotencyKey,
            if (revision == 0)
              'If-None-Match': '*'
            else
              'If-Match': '"rev-$revision"',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 30));
    if (!current()) throw const DatasetApiFailure('cancelled');
    if (response.statusCode == 401) {
      throw const DatasetApiFailure('session-expired');
    }
    if (response.statusCode == 403) {
      throw const DatasetApiFailure('forbidden');
    }
    if (response.statusCode == 412) {
      throw const DatasetApiFailure('draft-conflict');
    }
    if (response.statusCode == 409) {
      throw const DatasetApiFailure('idempotency-conflict');
    }
    if (response.statusCode == 429) {
      throw const DatasetApiFailure('rate-limited');
    }
    if (response.statusCode != 200) {
      throw const DatasetApiFailure('commit-unavailable');
    }
    try {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['protocolVersion'] != 1 ||
          data['revision'] is! int ||
          data['committedAt'] is! String ||
          data['actorId'] is! String) {
        throw const FormatException();
      }
      return BatchCommitResult(
        revision: data['revision'] as int,
        committedAt: data['committedAt'] as String,
        actorId: data['actorId'] as String,
      );
    } on FormatException {
      throw const DatasetApiFailure('invalid-dataset');
    } on TypeError {
      throw const DatasetApiFailure('invalid-dataset');
    }
  }

  @override
  void close() => client.close();
}

void validateDatasetRecord(Map<String, Object?> record) {
  final kind = record['resourceType'];
  final purged = record['state'] == 'purged';
  final keys = {
    'resourceType',
    'id',
    'state',
    'revision',
    if (!purged) 'name',
    if (kind == 'pack') 'topicId',
    if (kind == 'card') ...[
      'packId',
      if (!purged) ...['imageReference', 'difficulty'],
    ],
    'createdByUid',
    'createdAt',
  };
  if (!{'topic', 'pack', 'card'}.contains(kind) ||
      record['id'] is! String ||
      (record['id'] as String).isEmpty ||
      !{'active', 'hidden', 'deleted', 'purged'}.contains(record['state']) ||
      record['revision'] is! int ||
      (record['revision'] as int) < 1 ||
      (!purged && record['name'] is! String) ||
      (kind == 'pack' && record['topicId'] is! String) ||
      (kind == 'card' &&
          (record['packId'] is! String ||
              (!purged &&
                  (record['imageReference'] is! String ||
                      ![1, 2, 3].contains(record['difficulty']))))) ||
      record.keys.any((key) => !keys.contains(key))) {
    throw const FormatException('Invalid administrative record');
  }
}

void validateDatasetRelationships(List<Map<String, Object?>> records) {
  final topics = records
      .where((r) => r['resourceType'] == 'topic')
      .map((r) => r['id'])
      .toSet();
  final packs = records
      .where((r) => r['resourceType'] == 'pack')
      .map((r) => r['id'])
      .toSet();
  if (records.any(
    (r) =>
        r['resourceType'] == 'pack' && !topics.contains(r['topicId']) ||
        r['resourceType'] == 'card' && !packs.contains(r['packId']),
  )) {
    throw const FormatException('Incomplete administrative dataset');
  }
}
