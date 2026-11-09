import 'dart:async';

import 'package:biguess_studio/auth/studio_session.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeIdentity implements StudioIdentity {
  final controller = StreamController<String?>.broadcast(sync: true);
  String? currentToken = 'token-a';
  Object? restoreError;
  Object? tokenError;
  Object? popupError;
  Object? redirectError;
  Object? logoutError;
  Completer<void>? logoutCompletion;
  int refreshes = 0;
  int popups = 0;
  int redirects = 0;
  int signOuts = 0;

  @override
  Stream<String?> get changes => controller.stream;
  @override
  Future<void> restore() async {
    if (restoreError != null) throw restoreError!;
  }

  @override
  Future<String?> token({bool refresh = false}) async {
    if (refresh) refreshes++;
    if (tokenError != null) throw tokenError!;
    return currentToken;
  }

  @override
  Future<void> popup() async {
    popups++;
    if (popupError != null) throw popupError!;
  }

  @override
  Future<void> redirect() async {
    redirects++;
    if (redirectError != null) throw redirectError!;
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    await logoutCompletion?.future;
    if (logoutError != null) throw logoutError!;
    controller.add(null);
  }
}

class FakeAuthorization implements StudioAuthorization {
  Future<StudioPrincipal> Function(String)? handler;
  final tokens = <String>[];
  @override
  Future<StudioPrincipal> lookup(String token) async {
    tokens.add(token);
    return handler?.call(token) ??
        const StudioPrincipal('uid-a', 'a@example.test', 'owner_admin');
  }
}

Future<void> flush() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeIdentity identity;
  late FakeAuthorization authorization;
  late StudioSession session;
  setUp(() {
    identity = FakeIdentity();
    authorization = FakeAuthorization();
    session = StudioSession(identity, authorization);
  });
  tearDown(() async {
    session.dispose();
    await identity.controller.close();
  });

  for (final role in ['owner_admin', 'collector']) {
    test('restored $role requires a fresh Worker lookup', () async {
      authorization.handler = (_) async =>
          StudioPrincipal('uid-a', 'a@example.test', role);
      expect(session.phase, SessionPhase.restoring);
      expect(session.principal, isNull);
      await session.start();
      identity.controller.add('uid-a');
      expect(session.phase, SessionPhase.checking);
      expect(session.principal, isNull);
      await flush();
      expect(session.phase, SessionPhase.authorized);
      expect(session.principal?.role, role);
      expect(authorization.tokens, ['token-a']);
    });
  }

  test('logged-out restoration performs no authorization request', () async {
    await session.start();
    identity.controller.add(null);
    expect(session.phase, SessionPhase.signedOut);
    expect(session.principal, isNull);
    expect(authorization.tokens, isEmpty);
  });

  test('Google identity alone does not authorize access', () async {
    authorization.handler = (_) async =>
        throw const SessionFailure('forbidden');
    await session.start();
    identity.controller.add('uid-a');
    await flush();
    expect(session.phase, SessionPhase.denied);
    expect(session.principal, isNull);
  });

  test('role revocation clears a previously authorized principal', () async {
    await session.validate();
    expect(session.principal, isNotNull);
    authorization.handler = (_) async =>
        throw const SessionFailure('forbidden');
    final pending = session.validate(refresh: true);
    expect(session.principal, isNull);
    await pending;
    expect(session.phase, SessionPhase.denied);
    expect(identity.refreshes, 1);
  });

  for (final code in [
    'session-expired',
    'user-token-expired',
    'user-disabled',
  ]) {
    test('$code on refresh removes authorization immediately', () async {
      await session.validate();
      identity.tokenError = SessionFailure(code);
      await session.validate(refresh: true);
      expect(session.phase, SessionPhase.error);
      expect(session.errorCode, code);
      expect(session.principal, isNull);
    });
  }

  test('missing token never reaches Worker', () async {
    identity.currentToken = null;
    await session.validate();
    expect(session.errorCode, 'session-expired');
    expect(session.principal, isNull);
    expect(authorization.tokens, isEmpty);
  });

  test('offline first login fails closed and can retry', () async {
    identity.popupError = const SessionFailure('network-request-failed');
    await session.signIn();
    expect(session.phase, SessionPhase.error);
    expect(session.principal, isNull);
    expect(authorization.tokens, isEmpty);
    identity.popupError = null;
    await session.start();
    await session.signIn();
    identity.controller.add('uid-a');
    await flush();
    expect(session.phase, SessionPhase.authorized);
  });

  for (final code in [
    'popup-closed-by-user',
    'cancelled-popup-request',
    'popup-blocked',
    'web-storage-unsupported',
    'unauthorized-domain',
  ]) {
    test('popup failure $code exposes no identity or role', () async {
      identity.popupError = SessionFailure(code);
      await session.signIn();
      expect(session.phase, SessionPhase.error);
      expect(session.errorCode, code);
      expect(session.principal, isNull);
      expect(authorization.tokens, isEmpty);
    });
  }

  test('redirect invocation and restored completion use Worker', () async {
    await session.signIn(redirect: true);
    expect(identity.redirects, 1);
    expect(identity.popups, 0);
    expect(session.principal, isNull);
    await session.start();
    identity.controller.add('uid-a');
    await flush();
    expect(session.phase, SessionPhase.authorized);
  });

  test('redirect completion failure remains inaccessible', () async {
    identity.restoreError = const SessionFailure('invalid-auth-event');
    await session.start();
    expect(session.phase, SessionPhase.error);
    expect(session.errorCode, 'invalid-auth-event');
    expect(session.principal, isNull);
    expect(authorization.tokens, isEmpty);
  });

  test('redirect initiation storage failure remains inaccessible', () async {
    identity.redirectError = const SessionFailure('web-storage-unsupported');
    await session.signIn(redirect: true);
    expect(session.errorCode, 'web-storage-unsupported');
    expect(session.principal, isNull);
  });

  test('Worker connectivity loss removes an existing principal', () async {
    await session.validate();
    authorization.handler = (_) async => throw StateError('offline');
    await session.validate();
    expect(session.phase, SessionPhase.error);
    expect(session.errorCode, 'network-request-failed');
    expect(session.principal, isNull);
  });

  test('account switch clears old access before next explicit popup', () async {
    await session.start();
    await session.validate();
    await session.switchAccount();
    expect(session.phase, SessionPhase.signedOut);
    expect(session.principal, isNull);
    expect(identity.signOuts, 1);
    expect(identity.popups, 0);
    authorization.handler = (_) async =>
        const StudioPrincipal('uid-b', 'b@example.test', 'collector');
    identity.currentToken = 'token-b';
    await session.signIn();
    identity.controller.add('uid-b');
    await flush();
    expect(session.principal?.uid, 'uid-b');
    expect(authorization.tokens.last, 'token-b');
  });

  test(
    'pending logout blocks new sign-in and resume until completion',
    () async {
      await session.start();
      await session.validate();
      identity.logoutCompletion = Completer<void>();
      final pending = session.logout();
      expect(session.phase, SessionPhase.checking);
      expect(session.principal, isNull);
      await session.signIn();
      await session.signIn(redirect: true);
      await session.resume();
      identity.controller.add('uid-a');
      await flush();
      expect(identity.popups, 0);
      expect(identity.redirects, 0);
      expect(session.phase, SessionPhase.checking);
      expect(session.principal, isNull);

      identity.logoutCompletion!.complete();
      await pending;
      expect(session.phase, SessionPhase.signedOut);
      expect(session.principal, isNull);
      await session.signIn();
      expect(identity.popups, 1);
      identity.controller.add('uid-b');
      await flush();
      expect(session.phase, SessionPhase.authorized);
    },
  );

  test('failed logout keeps access cleared and reports the failure', () async {
    await session.validate();
    identity.logoutError = const SessionFailure('network-request-failed');
    await session.logout();
    expect(session.phase, SessionPhase.error);
    expect(session.errorCode, 'network-request-failed');
    expect(session.principal, isNull);
  });

  test('late Worker result cannot restore access after logout', () async {
    final response = Completer<StudioPrincipal>();
    authorization.handler = (_) => response.future;
    final pending = session.validate();
    await flush();
    await session.logout();
    response.complete(
      const StudioPrincipal('uid-a', 'a@example.test', 'owner_admin'),
    );
    await pending;
    expect(session.phase, SessionPhase.signedOut);
    expect(session.principal, isNull);
  });

  test('late previous-account response cannot overwrite new account', () async {
    final response = Completer<StudioPrincipal>();
    authorization.handler = (_) => response.future;
    final pending = session.validate();
    await flush();
    await session.switchAccount();
    await session.signIn();
    authorization.handler = (_) async =>
        const StudioPrincipal('uid-b', 'b@example.test', 'collector');
    await session.validate();
    response.complete(
      const StudioPrincipal('uid-a', 'a@example.test', 'owner_admin'),
    );
    await pending;
    expect(session.principal?.uid, 'uid-b');
  });

  test('late token stream after logout cannot restore access', () async {
    await session.start();
    await session.validate();
    await session.logout();
    identity.controller.add('uid-a');
    await flush();
    expect(session.phase, SessionPhase.signedOut);
    expect(session.principal, isNull);
  });

  test(
    'hidden session clears access and resumes with forced refresh',
    () async {
      await session.start();
      await session.validate();
      session.suspend();
      expect(session.principal, isNull);
      identity.controller.add('uid-a');
      expect(session.phase, SessionPhase.restoring);
      await session.resume();
      expect(identity.refreshes, 1);
      expect(session.phase, SessionPhase.authorized);
    },
  );

  test('auth stream failure clears previously granted access', () async {
    await session.start();
    await session.validate();
    identity.controller.addError(StateError('expired'));
    await flush();
    expect(session.errorCode, 'session-expired');
    expect(session.principal, isNull);
  });

  testWidgets('periodic check forces refresh and detects role revocation', (
    tester,
  ) async {
    session.dispose();
    session = StudioSession(
      identity,
      authorization,
      recheckInterval: const Duration(seconds: 2),
    );
    await session.start();
    await session.validate();
    authorization.handler = (_) async =>
        throw const SessionFailure('forbidden');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(identity.refreshes, 1);
    expect(session.phase, SessionPhase.denied);
    expect(session.principal, isNull);
    session.dispose();
    session = StudioSession(identity, authorization);
  });
}
