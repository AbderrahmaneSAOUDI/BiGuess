import 'dart:convert';

import 'package:biguess_studio/data/dataset_api.dart';
import 'package:biguess_studio/data/publication_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> publicationJson({bool ownerApproved = true}) => {
  'protocolVersion': 1,
  'resourceType': 'pack',
  'id': 'pack/id',
  'revision': 3,
  'fingerprint': 'a' * 64,
  'state': 'active',
  'published': false,
  'publishedRevision': null,
  'eligibleCardCount': 2,
  'cards': [
    for (final id in ['one', 'two'])
      {
        'id': id,
        'name': id,
        'difficulty': 1,
        'imageReference': 'objects/$id.png',
      },
  ],
  'errors': <String>[],
  'rightsApproved': true,
  'initialApproved': ownerApproved,
  'pendingRequestId': null,
};

Matcher failure(String code) =>
    isA<DatasetApiFailure>().having((error) => error.code, 'code', code);

void main() {
  test(
    'explicit publication action binds exact reviewed fingerprint and revision',
    () async {
      var calls = 0;
      final api = WorkerPublicationApi(
        Uri.parse('https://api.example'),
        MockClient((request) async {
          calls++;
          expect(
            request.url.toString(),
            'https://api.example/studio/v1/packs/pack%2Fid/publication/publish',
          );
          expect(request.method, 'POST');
          expect(request.headers['Authorization'], 'Bearer verified');
          expect(jsonDecode(request.body), {
            'revision': 3,
            'fingerprint': 'a' * 64,
          });
          return http.Response(
            jsonEncode({
              ...publicationJson(),
              'status': 'pending_operator',
              'pendingRequestId': 'release-1',
            }),
            202,
          );
        }),
      );
      addTearDown(api.close);
      final result = await api.review(
        'verified',
        'pack',
        'pack/id',
        () => true,
        action: 'publish',
        expected: PublicationReview.fromJson(publicationJson()),
      );
      expect(result.published, false);
      expect(result.pendingRequestId, 'release-1');
      expect(calls, 1);
    },
  );

  test('late account change discards successful response', () async {
    var current = true;
    final api = WorkerPublicationApi(
      Uri.parse('https://api.example'),
      MockClient((request) async {
        current = false;
        return http.Response(jsonEncode(publicationJson()), 200);
      }),
    );
    addTearDown(api.close);
    await expectLater(
      api.review('old-token', 'pack', 'pack/id', () => current),
      throwsA(failure('cancelled')),
    );
  });

  test(
    'response identity and protocol are verified rather than trusting success',
    () async {
      for (final changed in [
        {'id': 'foreign'},
        {'protocolVersion': 2},
        {'rightsApproved': 'true'},
        {'fingerprint': 'arbitrary'},
        {
          'cards': [
            {'name': 'incomplete'},
          ],
        },
      ]) {
        final api = WorkerPublicationApi(
          Uri.parse('https://api.example'),
          MockClient(
            (request) async => http.Response(
              jsonEncode({...publicationJson(), ...changed}),
              200,
            ),
          ),
        );
        await expectLater(
          api.review('token', 'pack', 'pack/id', () => true),
          throwsA(failure('invalid-publication-review')),
        );
        api.close();
      }
    },
  );

  test('Card publishing and calls without exact reviewed state never reach network', () async {
    final api = WorkerPublicationApi(
      Uri.parse('https://api.example'),
      MockClient((request) async => throw StateError('must not send')),
    );
    addTearDown(api.close);
    await expectLater(
      api.review('token', 'card', 'one', () => true),
      throwsA(failure('invalid-publication-action')),
    );
    await expectLater(
      api.review('token', 'pack', 'pack/id', () => true, action: 'publish'),
      throwsA(failure('invalid-publication-action')),
    );
  });

  test('stale review and denied access remain actionable', () async {
    for (final entry in {
      401: 'session-expired',
      403: 'forbidden',
      412: 'publication-conflict',
      422: 'publication-invalid',
      503: 'publication-unavailable',
    }.entries) {
      final api = WorkerPublicationApi(
        Uri.parse('https://api.example'),
        MockClient((request) async => http.Response('{}', entry.key)),
      );
      await expectLater(
        api.review('token', 'pack', 'pack/id', () => true),
        throwsA(failure(entry.value)),
      );
      api.close();
    }
  });
}
