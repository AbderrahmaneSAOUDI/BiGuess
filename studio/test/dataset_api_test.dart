import 'dart:convert';

import 'package:biguess_studio/data/dataset_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> topic([String id = 'topic']) => {
  'resourceType': 'topic',
  'id': id,
  'name': id,
  'state': 'hidden',
  'revision': 1,
};
Map<String, Object?> pack([String id = 'pack']) => {
  'resourceType': 'pack',
  'id': id,
  'topicId': 'topic',
  'name': id,
  'state': 'active',
  'revision': 1,
};
http.Response page(
  List<Map<String, Object?>> records, {
  String? next,
  String? resume,
}) => http.Response(
  jsonEncode({
    'protocolVersion': 1,
    'scopeVersion': 1,
    'items': records,
    'nextCursor': next,
    'resumeCursor': resume,
  }),
  200,
);
Matcher apiFailure(String code) =>
    isA<DatasetApiFailure>().having((e) => e.code, 'code', code);

void main() {
  test(
    'uses canonical scoped endpoint and bearer on every staged page',
    () async {
      final requests = <http.Request>[];
      final api = WorkerDatasetApi(
        Uri.parse('https://api.example'),
        MockClient((request) async {
          requests.add(request);
          if (requests.length == 1) {
            return page([topic()], next: 'opaque+page/2');
          }
          return page([pack()], resume: 'opaque-resume');
        }),
      );
      addTearDown(api.close);
      final result = await api.initial('private-token', () => true);
      expect(result.records.map((r) => r['id']), ['topic', 'pack']);
      expect(result.resumeCursor, 'opaque-resume');
      expect(requests, hasLength(2));
      for (final request in requests) {
        expect(request.method, 'GET');
        expect(request.url.path, '/studio/v1/sync/initial');
        expect(request.url.queryParameters['limit'], '100');
        expect(request.headers['Authorization'], 'Bearer private-token');
        expect(request.url.queryParameters.containsKey('token'), false);
      }
      expect(requests.last.url.queryParameters['cursor'], 'opaque+page/2');
    },
  );

  test(
    'expired scan restarts once, discarding all first-attempt staged rows',
    () async {
      var calls = 0;
      final api = WorkerDatasetApi(
        Uri.parse('https://api.example'),
        MockClient((request) async {
          calls++;
          if (calls == 1) return page([topic('discarded')], next: 'old');
          if (calls == 2) return http.Response('{}', 409);
          expect(request.url.queryParameters['cursor'], null);
          return page([topic()], resume: 'new-resume');
        }),
      );
      addTearDown(api.close);
      final result = await api.initial('token', () => true);
      expect(calls, 3);
      expect(result.records.single['id'], 'topic');
      expect(result.resumeCursor, 'new-resume');
    },
  );

  test(
    'repeated expiry has a bounded retry and never returns a partial scan',
    () async {
      var calls = 0;
      final api = WorkerDatasetApi(
        Uri.parse('https://api.example'),
        MockClient((_) async {
          calls++;
          return http.Response('{}', 409);
        }),
      );
      addTearDown(api.close);
      await expectLater(
        api.initial('token', () => true),
        throwsA(apiFailure('cursor_expired')),
      );
      expect(calls, 2);
    },
  );

  for (final (status, code) in [
    (401, 'session-expired'),
    (403, 'forbidden'),
    (503, 'sync-unavailable'),
  ]) {
    test(
      'HTTP $status fails closed without a partial result or automatic retries',
      () async {
        var calls = 0;
        final api = WorkerDatasetApi(
          Uri.parse('https://api.example'),
          MockClient((_) async {
            calls++;
            return http.Response('{}', status);
          }),
        );
        addTearDown(api.close);
        await expectLater(
          api.initial('token', () => true),
          throwsA(apiFailure(code)),
        );
        expect(calls, 1);
      },
    );
  }

  test(
    'cancelled account prevents issuing requests and ignores late pages',
    () async {
      var current = false;
      var calls = 0;
      final api = WorkerDatasetApi(
        Uri.parse('https://api.example'),
        MockClient((_) async {
          calls++;
          current = false;
          return page([topic()], resume: 'resume');
        }),
      );
      addTearDown(api.close);
      await expectLater(
        api.initial('token', () => current),
        throwsA(apiFailure('cancelled')),
      );
      expect(calls, 0);
      current = true;
      await expectLater(
        api.initial('token', () => current),
        throwsA(apiFailure('cancelled')),
      );
      expect(calls, 1);
    },
  );

  final malformed = <String, http.Response>{
    'duplicate identities': page([topic(), topic()], resume: 'r'),
    'orphan Pack': page([pack()], resume: 'r'),
    'missing complete watermark': page([topic()]),
    'premature resume watermark': page([topic()], next: 'next', resume: 'r'),
    'empty continuation': page([topic()], next: ''),
    'unexpected privileged fields': page([
      {...topic(), 'accessToken': 'forbidden'},
    ], resume: 'r'),
    'invalid JSON': http.Response('{', 200),
    'wrong scope protocol': http.Response(
      jsonEncode({
        'protocolVersion': 1,
        'scopeVersion': 2,
        'items': [],
        'nextCursor': null,
        'resumeCursor': 'r',
      }),
      200,
    ),
  };
  for (final entry in malformed.entries) {
    test('rejects ${entry.key}', () async {
      final api = WorkerDatasetApi(
        Uri.parse('https://api.example'),
        MockClient((_) async => entry.value),
      );
      addTearDown(api.close);
      await expectLater(
        api.initial('token', () => true),
        throwsA(apiFailure('invalid-dataset')),
      );
    });
  }

  test(
    'repeating continuation handles cannot create an infinite scan',
    () async {
      var calls = 0;
      final api = WorkerDatasetApi(
        Uri.parse('https://api.example'),
        MockClient((_) async {
          calls++;
          return page([topic('topic-$calls')], next: 'repeat');
        }),
      );
      addTearDown(api.close);
      await expectLater(
        api.initial('token', () => true),
        throwsA(apiFailure('invalid-dataset')),
      );
      expect(calls, 2);
    },
  );
}
