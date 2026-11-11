import 'dart:async';

import 'package:biguess_studio/auth/studio_session.dart';
import 'package:biguess_studio/data/dataset_api.dart';
import 'package:biguess_studio/data/profile_api.dart';
import 'package:biguess_studio/data/profile_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'profile_api_test.dart' show profileJson;

class Identity implements StudioIdentity {
  String uid = 'a';
  @override
  Future<String?> token({bool refresh = false}) async => uid;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Authorization implements StudioAuthorization {
  String role = 'collector';
  String? failure;
  int calls = 0;
  @override
  Future<StudioPrincipal> lookup(String token) async {
    calls++;
    if (failure != null) throw SessionFailure(failure!);
    return StudioPrincipal(token, '$token@example.test', role);
  }
}

class Api implements ProfileApi {
  int calls = 0;
  Future<ContributorProfile> Function(String?, String?)? handler;
  @override
  Future<ContributorProfile> read(
    String token,
    bool Function() current, {
    String? contributorUid,
    String? cursor,
  }) async {
    calls++;
    return handler?.call(contributorUid, cursor) ??
        ContributorProfile.fromJson(profileJson(uid: token));
  }

  @override
  void close() {}
}

void main() {
  late Identity identity;
  late Authorization authorization;
  late StudioSession session;
  late Api api;
  late ProfileController controller;
  setUp(() async {
    identity = Identity();
    authorization = Authorization();
    session = StudioSession(identity, authorization);
    await session.validate();
    api = Api();
    controller = ProfileController(session: session, api: api);
  });
  tearDown(() {
    controller.dispose();
    session.dispose();
  });

  test(
    'no automatic reads; Refresh rechecks server role and scoped activity',
    () async {
      expect(api.calls, 0);
      final checks = authorization.calls;
      await controller.refresh();
      expect(api.calls, 1);
      expect(authorization.calls, checks + 2);
      expect(controller.profile!.principal.uid, 'a');
      expect(controller.profile!.counts.values['packsCreated'], 1);
      expect(controller.errorCode, isNull);
    },
  );
  test(
    'role change during response rejects Owner data before display',
    () async {
      authorization.role = 'owner_admin';
      await session.validate();
      api.handler = (_, _) async {
        authorization.role = 'collector';
        return ContributorProfile.fromJson(
          profileJson(uid: 'a', role: 'owner_admin'),
        );
      };
      await controller.refresh();
      expect(controller.profile, isNull);
      expect(session.errorCode, 'scope-changed');
    },
  );
  test('revoked identity never requests statistics', () async {
    authorization.failure = 'forbidden';
    await controller.refresh();
    expect(api.calls, 0);
    expect(controller.profile, isNull);
    expect(session.phase, SessionPhase.denied);
  });
  test(
    'late old-account failure cannot revoke the newly authorized account',
    () async {
      final pending = Completer<ContributorProfile>();
      api.handler = (_, _) => pending.future;
      final operation = controller.refresh();
      while (api.calls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      identity.uid = 'b';
      session.identityUid = 'b';
      await session.validate();
      pending.completeError(const DatasetApiFailure('forbidden'));
      await operation;
      expect(session.phase, SessionPhase.authorized);
      expect(session.principal!.uid, 'b');
      expect(controller.profile, isNull);
    },
  );
  test('late old-account success is discarded', () async {
    final pending = Completer<ContributorProfile>();
    api.handler = (_, _) => pending.future;
    final operation = controller.refresh();
    while (api.calls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    session.rejectAuthorization('forbidden');
    pending.complete(ContributorProfile.fromJson(profileJson()));
    await operation;
    expect(controller.profile, isNull);
  });
  test('failed next page keeps earlier page; expired cursor requires explicit Refresh', () async {
    api.handler = (_, _) async =>
        ContributorProfile.fromJson(profileJson(next: 'next'));
    await controller.refresh();
    final previous = controller.profile;
    api.handler = (_, cursor) async {
      expect(cursor, 'next');
      throw const DatasetApiFailure('cursor_expired');
    };
    await controller.refresh(more: true);
    expect(controller.errorCode, 'cursor_expired');
    expect(controller.profile, same(previous));
  });
  test(
    'an account event clears existing private profile immediately',
    () async {
      await controller.refresh();
      expect(controller.profile, isNotNull);
      session.rejectAuthorization('scope-changed');
      expect(controller.profile, isNull);
    },
  );
}
