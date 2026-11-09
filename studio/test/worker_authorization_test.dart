import 'dart:convert';

import 'package:biguess_studio/auth/studio_session.dart';
import 'package:biguess_studio/auth/worker_authorization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  for (final role in ['owner_admin', 'collector']) {
    test(
      'Worker $role response grants only the returned server principal',
      () async {
        final client = MockClient((request) async {
          expect(
            request.url.toString(),
            'https://api.example.test/content/v1/studio/session',
          );
          expect(request.headers['Authorization'], 'Bearer firebase-id-token');
          // Server responses prohibit caching; avoid extra preflight headers.
          expect(request.headers.containsKey('Cache-Control'), isFalse);
          expect(request.url.query, isEmpty);
          return http.Response(
            jsonEncode({
              'uid': 'uid',
              'email': 'user@example.test',
              'role': role,
            }),
            200,
          );
        });
        addTearDown(client.close);
        final auth = WorkerAuthorization(
          Uri.parse('https://api.example.test'),
          client,
        );
        final principal = await auth.lookup('firebase-id-token');
        expect(principal.uid, 'uid');
        expect(principal.email, 'user@example.test');
        expect(principal.role, role);
      },
    );
  }

  for (final entry in {
    401: 'session-expired',
    403: 'forbidden',
    500: 'authorization-unavailable',
    503: 'authorization-unavailable',
  }.entries) {
    test('HTTP ${entry.key} fails closed with ${entry.value}', () async {
      final client = MockClient((_) async => http.Response('{}', entry.key));
      addTearDown(client.close);
      final auth = WorkerAuthorization(
        Uri.parse('https://api.example.test'),
        client,
      );
      await expectLater(
        auth.lookup('token'),
        throwsA(
          isA<SessionFailure>().having(
            (error) => error.code,
            'code',
            entry.value,
          ),
        ),
      );
    });
  }

  for (final data in [
    {'uid': 'u', 'email': 'e', 'role': 'admin'},
    {'uid': 'u', 'email': 'e', 'role': 'moderator'},
    {'uid': '', 'email': 'e', 'role': 'owner_admin'},
    {'uid': 42, 'email': 'e', 'role': 'collector'},
    {'uid': 'u', 'role': 'collector'},
    {'role': 'collector'},
  ]) {
    test('malformed or unsupported principal $data grants no role', () async {
      final client = MockClient(
        (_) async => http.Response(jsonEncode(data), 200),
      );
      addTearDown(client.close);
      final auth = WorkerAuthorization(
        Uri.parse('https://api.example.test'),
        client,
      );
      await expectLater(auth.lookup('token'), throwsA(isA<SessionFailure>()));
    });
  }

  test('invalid JSON cannot authorize an account', () async {
    final client = MockClient((_) async => http.Response('invalid', 200));
    addTearDown(client.close);
    final auth = WorkerAuthorization(
      Uri.parse('https://api.example.test'),
      client,
    );
    await expectLater(auth.lookup('token'), throwsA(isA<FormatException>()));
  });

  test('offline request never supplies a cached principal', () async {
    final client = MockClient(
      (_) async => throw http.ClientException('offline'),
    );
    addTearDown(client.close);
    final auth = WorkerAuthorization(
      Uri.parse('https://api.example.test'),
      client,
    );
    await expectLater(
      auth.lookup('token'),
      throwsA(isA<http.ClientException>()),
    );
  });

  for (final url in [
    'http://api.example.test',
    'https://user:password@api.example.test',
    'https://api.example.test?token=x',
    'https://api.example.test#fragment',
    'file:///tmp/auth',
  ]) {
    test('reject unsafe authorization endpoint $url', () {
      final client = MockClient((_) async => http.Response('{}', 200));
      addTearDown(client.close);
      expect(
        () => WorkerAuthorization(Uri.parse(url), client),
        throwsArgumentError,
      );
    });
  }

  for (final url in ['http://localhost:7357', 'http://127.0.0.1:7357']) {
    test('explicit loopback development endpoint accepted: $url', () {
      final client = MockClient((_) async => http.Response('{}', 200));
      addTearDown(client.close);
      expect(WorkerAuthorization(Uri.parse(url), client).base.toString(), url);
    });
  }
}
