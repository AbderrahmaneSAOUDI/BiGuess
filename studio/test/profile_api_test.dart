import 'dart:convert';

import 'package:biguess_studio/data/dataset_api.dart';
import 'package:biguess_studio/data/profile_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> profileJson({
  String uid = 'a',
  String role = 'collector',
  String? contributorUid,
  String? next,
  String id = 'pack-a',
}) => {
  'protocolVersion': 1,
  'scopeVersion': 1,
  'principal': {'uid': uid, 'email': '$uid@example.test', 'role': role},
  'counts': {
    for (final key in ContributionCounts.labels.keys)
      key: {'totalOperations', 'packsCreated'}.contains(key) ? 1 : 0,
  },
  'contributors': role == 'collector'
      ? []
      : [
          {
            'uid': 'a',
            'email': 'a@example.test',
            'role': 'collector',
            'counts': {
              for (final key in ContributionCounts.labels.keys)
                key: {'totalOperations', 'packsCreated'}.contains(key) ? 1 : 0,
            },
          },
        ],
  'activity': [
    {
      'batchId': 'batch-$id',
      'actorId': role == 'collector' ? uid : 'a',
      'actorRole': 'collector',
      'resourceType': 'pack',
      'resourceId': id,
      'action': 'create',
      'revision': 1,
      'committedAt': '2026-11-11T12:00:00Z',
    },
  ],
  'nextCursor': next,
  'asOf': '2026-11-11T12:00:01Z',
  'contributorUid': contributorUid,
};
Matcher profileFailure(String code) =>
    isA<DatasetApiFailure>().having((e) => e.code, 'code', code);

void main() {
  test('profile request is authenticated and binds Owner filter and opaque page cursor', () async {
    final api = WorkerProfileApi(
      Uri.parse('https://api.example'),
      MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/studio/v1/profile');
        expect(request.headers['Authorization'], 'Bearer private-token');
        expect(request.url.queryParameters, {
          'limit': '50',
          'contributorUid': 'a',
          'cursor': 'opaque+/page',
        });
        expect(request.url.toString(), isNot(contains('private-token')));
        return http.Response(
          jsonEncode(
            profileJson(uid: 'owner', role: 'owner_admin', contributorUid: 'a'),
          ),
          200,
        );
      }),
    );
    addTearDown(api.close);
    final profile = await api.read(
      'private-token',
      () => true,
      contributorUid: 'a',
      cursor: 'opaque+/page',
    );
    expect(profile.counts.values['packsCreated'], 1);
    expect(profile.contributors.single.uid, 'a');
  });

  for (final (status, code) in [
    (401, 'session-expired'),
    (403, 'forbidden'),
    (409, 'cursor_expired'),
    (503, 'profile-unavailable'),
  ]) {
    test(
      'HTTP $status is explicit and never returns partial profile',
      () async {
        final api = WorkerProfileApi(
          Uri.parse('https://api.example'),
          MockClient((_) async => http.Response('{}', status)),
        );
        addTearDown(api.close);
        await expectLater(
          api.read('token', () => true),
          throwsA(profileFailure(code)),
        );
      },
    );
  }

  test(
    'late account cancellation discards success and prevents further calls',
    () async {
      var current = true;
      var calls = 0;
      final api = WorkerProfileApi(
        Uri.parse('https://api.example'),
        MockClient((_) async {
          calls++;
          current = false;
          return http.Response(jsonEncode(profileJson()), 200);
        }),
      );
      addTearDown(api.close);
      await expectLater(
        api.read('token', () => current),
        throwsA(profileFailure('cancelled')),
      );
      await expectLater(
        api.read('token', () => current),
        throwsA(profileFailure('cancelled')),
      );
      expect(calls, 1);
    },
  );

  final malformed = <String, Map<String, Object?>>{
    'Collector roster': {
      ...profileJson(),
      'contributors': (profileJson(role: 'owner_admin')['contributors']),
    },
    'Collector foreign activity': {
      ...profileJson(),
      'activity': (profileJson(uid: 'b')['activity']),
    },
    'Collector filter': {...profileJson(), 'contributorUid': 'a'},
    'nonreconciling totals': {
      ...profileJson(),
      'counts': {
        for (final key in ContributionCounts.labels.keys) key: 0,
        'totalOperations': 50,
      },
    },
    'wrong protocol': {...profileJson(), 'scopeVersion': 2},
    'negative count': {
      ...profileJson(),
      'counts': {
        for (final key in ContributionCounts.labels.keys) key: 0,
        'cardsAdded': -1,
      },
    },
    'unknown action': {
      ...profileJson(),
      'activity': [
        {
          ...((profileJson()['activity'] as List).single as Map),
          'action': 'batch',
        },
      ],
    },
  };
  for (final entry in malformed.entries) {
    test('rejects ${entry.key}', () async {
      final api = WorkerProfileApi(
        Uri.parse('https://api.example'),
        MockClient((_) async => http.Response(jsonEncode(entry.value), 200)),
      );
      addTearDown(api.close);
      await expectLater(
        api.read('token', () => true),
        throwsA(profileFailure('invalid-profile')),
      );
    });
  }

  test('pagination rejects different snapshots and duplicate rows', () {
    final first = ContributorProfile.fromJson(profileJson(next: 'next'));
    final next = ContributorProfile.fromJson(profileJson(id: 'pack-next'));
    expect(first.append(next).activity, hasLength(2));
    expect(
      () => first.append(first),
      throwsA(profileFailure('invalid-profile')),
    );
    expect(
      () => first.append(
        ContributorProfile.fromJson({
          ...profileJson(id: 'new'),
          'asOf': '2026-11-11T12:00:02Z',
        }),
      ),
      throwsA(profileFailure('invalid-profile')),
    );
  });
}
