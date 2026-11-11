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

  group('incremental changes', () {
    test('unchanged refresh requests only the scoped feed', () async {
      final original = [topic(), pack()];
      final api = WorkerDatasetApi(
        Uri.parse('https://api.example'),
        MockClient((request) async {
          expect(request.url.path, '/studio/v1/sync/changes');
          expect(request.url.queryParameters, {
            'limit': '100',
            'cursor': 'opaque+resume/1',
          });
          expect(request.headers['Authorization'], 'Bearer token');
          return page([], resume: 'resume-2');
        }),
      );
      addTearDown(api.close);
      final result = await api.changes(
        'token',
        original,
        'opaque+resume/1',
        () => true,
      );
      expect(result.records, original);
      expect(result.resumeCursor, 'resume-2');
    });

    test('stages all pages and applies ordered upserts and removals', () async {
      final original = [topic(), pack()];
      var calls = 0;
      final api = WorkerDatasetApi(
        Uri.parse('https://api.example'),
        MockClient((request) async {
          calls++;
          if (calls == 1) {
            return page([
              {
                'kind': 'upsert',
                'record': {...pack(), 'name': 'Updated', 'revision': 2},
              },
            ], next: 'second');
          }
          expect(request.url.queryParameters['cursor'], 'second');
          return page([
            {
              'kind': 'remove',
              'resourceType': 'pack',
              'id': 'pack',
              'revision': 3,
            },
            {
              'kind': 'upsert',
              'record': {...topic(), 'name': 'Renamed', 'revision': 2},
            },
          ], resume: 'complete');
        }),
      );
      addTearDown(api.close);
      final result = await api.changes('token', original, 'start', () => true);
      expect(result.records.single['name'], 'Renamed');
      expect(result.resumeCursor, 'complete');
      expect(original[1]['name'], 'pack');
      expect(calls, 2);
    });

    test(
      'Owner removals rebuild lifecycle rows from a complete scan',
      () async {
        var calls = 0;
        final deleted = {
          ...pack(),
          'state': 'deleted',
          'revision': 2,
          'createdByUid': 'collector',
          'createdAt': '2026-11-11T00:00:00Z',
        };
        final api = WorkerDatasetApi(
          Uri.parse('https://api.example'),
          MockClient((request) async {
            calls++;
            if (calls == 1) {
              expect(request.url.path, '/studio/v1/sync/changes');
              return page([
                {
                  'kind': 'remove',
                  'resourceType': 'pack',
                  'id': 'pack',
                  'revision': 2,
                },
              ], resume: 'feed-complete');
            }
            expect(request.url.path, '/studio/v1/sync/initial');
            return page([topic(), deleted], resume: 'full-complete');
          }),
        );
        addTearDown(api.close);
        final result = await api.changes(
          'token',
          [topic(), pack()],
          'start',
          () => true,
          owner: true,
        );
        expect(result.records.last, deleted);
        expect(result.resumeCursor, 'full-complete');
        expect(calls, 2);
      },
    );

    test(
      'older feed events cannot replace acknowledged newer records',
      () async {
        final newer = {...pack(), 'name': 'Committed', 'revision': 3};
        final api = WorkerDatasetApi(
          Uri.parse('https://api.example'),
          MockClient(
            (_) async => page([
              {'kind': 'upsert', 'record': pack()},
              {
                'kind': 'remove',
                'resourceType': 'pack',
                'id': 'pack',
                'revision': 2,
              },
            ], resume: 'complete'),
          ),
        );
        addTearDown(api.close);
        final result = await api.changes(
          'token',
          [topic(), newer],
          'start',
          () => true,
        );
        expect(result.records.last['name'], 'Committed');
      },
    );

    test(
      'expired feed discards staging and falls back to bounded initial scan',
      () async {
        var calls = 0;
        final api = WorkerDatasetApi(
          Uri.parse('https://api.example'),
          MockClient((request) async {
            calls++;
            if (calls == 1) {
              return page([
                {'kind': 'upsert', 'record': topic('discarded')},
              ], next: 'expired');
            }
            if (calls == 2) return http.Response('{}', 409);
            expect(request.url.path, '/studio/v1/sync/initial');
            return page([topic()], resume: 'fresh');
          }),
        );
        addTearDown(api.close);
        final result = await api.changes(
          'token',
          [topic('old')],
          'start',
          () => true,
        );
        expect(result.records.single['id'], 'topic');
        expect(calls, 3);
      },
    );

    for (final (status, code) in [
      (401, 'session-expired'),
      (403, 'forbidden'),
      (503, 'sync-unavailable'),
    ]) {
      test(
        'failed later page ($status) leaves the original dataset intact',
        () async {
          final original = [topic()];
          var calls = 0;
          final api = WorkerDatasetApi(
            Uri.parse('https://api.example'),
            MockClient((_) async {
              calls++;
              return calls == 1
                  ? page([
                      {'kind': 'upsert', 'record': pack()},
                    ], next: 'second')
                  : http.Response('{}', status);
            }),
          );
          addTearDown(api.close);
          await expectLater(
            api.changes('token', original, 'start', () => true),
            throwsA(apiFailure(code)),
          );
          expect(original, [topic()]);
          expect(calls, 2);
        },
      );
    }

    test('cancellation prevents requests and rejects late responses', () async {
      var current = false;
      var calls = 0;
      final api = WorkerDatasetApi(
        Uri.parse('https://api.example'),
        MockClient((_) async {
          calls++;
          current = false;
          return page([], resume: 'complete');
        }),
      );
      addTearDown(api.close);
      await expectLater(
        api.changes('token', [topic()], 'start', () => current),
        throwsA(apiFailure('cancelled')),
      );
      expect(calls, 0);
      current = true;
      await expectLater(
        api.changes('token', [topic()], 'start', () => current),
        throwsA(apiFailure('cancelled')),
      );
      expect(calls, 1);
    });

    final malformedEvents = {
      'privileged removal fields': page([
        {
          'kind': 'remove',
          'resourceType': 'pack',
          'id': 'pack',
          'revision': 2,
          'name': 'private',
        },
      ], resume: 'complete'),
      'unknown event kind': page([
        {'kind': 'unexpected'},
      ], resume: 'complete'),
      'invalid upsert': page([
        {
          'kind': 'upsert',
          'record': {'id': 'bad'},
        },
      ], resume: 'complete'),
      'orphan result': page([
        {'kind': 'upsert', 'record': pack()},
      ], resume: 'complete'),
      'missing watermark': page([]),
      'premature watermark': page([], next: 'next', resume: 'early'),
      'repeated cursor': page([], next: 'start'),
    };
    for (final entry in malformedEvents.entries) {
      test('rejects ${entry.key} without promoting staging', () async {
        final api = WorkerDatasetApi(
          Uri.parse('https://api.example'),
          MockClient((_) async => entry.value),
        );
        addTearDown(api.close);
        await expectLater(
          api.changes('token', [], 'start', () => true),
          throwsA(apiFailure('invalid-dataset')),
        );
      });
    }
  });

  group('WorkerDatasetApi.commitBatch', () {
    test(
      'sends POST /studio/v1/batches with valid headers and parses result',
      () async {
        http.Request? captured;
        final api = WorkerDatasetApi(
          Uri.parse('https://api.example'),
          MockClient((request) async {
            captured = request;
            return http.Response(
              jsonEncode({
                'protocolVersion': 1,
                'aggregate': {'resourceType': 'pack', 'id': 'p1'},
                'revision': 2,
                'committedAt': '2026-11-11T00:00:00Z',
                'actorId': 'user-1',
              }),
              200,
            );
          }),
        );
        addTearDown(api.close);

        final batch = {
          'protocolVersion': 1,
          'aggregate': {'resourceType': 'pack', 'id': 'p1'},
          'operations': [
            {'resourceType': 'card', 'id': 'c1', 'action': 'create'},
          ],
        };

        final result = await api.commitBatch(
          'test-token',
          idempotencyKey: 'key-123',
          revision: 1,
          batch: batch,
          current: () => true,
        );

        expect(result.revision, 2);
        expect(result.committedAt, '2026-11-11T00:00:00Z');
        expect(result.actorId, 'user-1');
        expect(captured!.method, 'POST');
        expect(captured!.url.path, '/studio/v1/batches');
        expect(captured!.headers['Authorization'], 'Bearer test-token');
        expect(captured!.headers['Idempotency-Key'], 'key-123');
        expect(captured!.headers['If-Match'], '"rev-1"');
        expect(captured!.headers['Content-Type'], 'application/json');
      },
    );

    test('new aggregate uses create-only precondition', () async {
      final api = WorkerDatasetApi(
        Uri.parse('https://api.example'),
        MockClient((request) async {
          expect(request.headers['If-None-Match'], '*');
          expect(request.headers.containsKey('If-Match'), false);
          return http.Response(
            jsonEncode({
              'protocolVersion': 1,
              'revision': 1,
              'committedAt': '2026-11-11T00:00:00Z',
              'actorId': 'user-1',
            }),
            200,
          );
        }),
      );
      addTearDown(api.close);
      final result = await api.commitBatch(
        'token',
        idempotencyKey: 'new-key',
        revision: 0,
        batch: const {},
        current: () => true,
      );
      expect(result.revision, 1);
    });

    test('maps status codes to DatasetApiFailure', () async {
      for (final (status, code) in [
        (401, 'session-expired'),
        (403, 'forbidden'),
        (412, 'draft-conflict'),
        (409, 'idempotency-conflict'),
        (429, 'rate-limited'),
        (500, 'commit-unavailable'),
      ]) {
        final api = WorkerDatasetApi(
          Uri.parse('https://api.example'),
          MockClient((_) async => http.Response('{}', status)),
        );
        await expectLater(
          api.commitBatch(
            'token',
            idempotencyKey: 'k',
            revision: 1,
            batch: const {},
            current: () => true,
          ),
          throwsA(apiFailure(code)),
        );
        api.close();
      }
    });

    test('rejects batch exceeding 256 KiB before transport', () async {
      var called = false;
      final api = WorkerDatasetApi(
        Uri.parse('https://api.example'),
        MockClient((_) async {
          called = true;
          return http.Response('{}', 200);
        }),
      );
      addTearDown(api.close);

      final hugeBatch = {
        'protocolVersion': 1,
        'aggregate': {'resourceType': 'pack', 'id': 'p1'},
        'operations': List.generate(
          1000,
          (i) => {'resourceType': 'card', 'id': 'c$i', 'padding': 'x' * 300},
        ),
      };

      await expectLater(
        api.commitBatch(
          'token',
          idempotencyKey: 'k',
          revision: 1,
          batch: hugeBatch,
          current: () => true,
        ),
        throwsA(apiFailure('batch-too-large')),
      );
      expect(called, isFalse);
    });

    test('cancelled check stops before transport', () async {
      var called = false;
      final api = WorkerDatasetApi(
        Uri.parse('https://api.example'),
        MockClient((_) async {
          called = true;
          return http.Response('{}', 200);
        }),
      );
      addTearDown(api.close);

      await expectLater(
        api.commitBatch(
          'token',
          idempotencyKey: 'k',
          revision: 1,
          batch: const {},
          current: () => false,
        ),
        throwsA(apiFailure('cancelled')),
      );
      expect(called, isFalse);
    });
  });
}
