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

abstract interface class DatasetApi {
  Future<InitialDataset> initial(String token, bool Function() current);
  void close();
}

/// All pages stage in memory; callers promote only a complete, validated scan.
class WorkerDatasetApi implements DatasetApi {
  WorkerDatasetApi(this.base, this.client);
  final Uri base;
  final http.Client client;

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
