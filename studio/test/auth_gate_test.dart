import 'dart:async';

import 'package:biguess_studio/app/studio_app.dart';
import 'package:biguess_studio/app/studio_route.dart';
import 'package:biguess_studio/auth/studio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class Identity implements StudioIdentity {
  final events = StreamController<String?>.broadcast();
  @override
  Stream<String?> get changes => events.stream;
  @override
  Future<void> restore() async {}
  @override
  Future<String?> token({bool refresh = false}) async => 'token';
  @override
  Future<void> popup() async {
    events.add('user');
  }

  @override
  Future<void> redirect() async {
    events.add('user');
  }

  @override
  Future<void> signOut() async {
    events.add(null);
  }
}

class Authorization implements StudioAuthorization {
  String role = 'owner_admin';
  @override
  Future<StudioPrincipal> lookup(String token) async {
    if (role == 'denied') throw const SessionFailure('forbidden');
    return StudioPrincipal('user', 'user@example.test', role);
  }
}

void main() {
  for (final role in ['owner_admin', 'collector']) {
    testWidgets(
      '$role shell clears on logout, denial, background and deep links',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final identity = Identity();
        final authorization = Authorization()..role = role;
        final session = StudioSession(identity, authorization);

        addTearDown(identity.events.close);
        await session.start();
        await tester.pumpWidget(StudioApp(session: session));
        await tester.pump();
        expect(find.byType(NavigationRail), findsNothing);
        identity.events.add(null);
        await tester.pumpAndSettle();
        expect(find.text('Continue with Google'), findsOneWidget);
        // A browser history/deep link cannot bypass the gate.
        final router =
            Router.of(tester.element(find.byType(Navigator))).routerDelegate
                as StudioRouter;
        await router.setNewRoutePath(StudioRoute.cards);
        router.notifyListeners();
        await tester.pumpAndSettle();
        expect(find.text('Cards'), findsNothing);
        await tester.tap(find.text('Continue with Google'));
        await tester.pumpAndSettle();
        expect(find.byType(NavigationRail), findsOneWidget);
        expect(find.text('Cards'), findsNWidgets(2));
        session.suspend();
        await tester.pump();
        expect(find.byType(NavigationRail), findsNothing);
        authorization.role = 'denied';
        await session.resume();
        await tester.pumpAndSettle();
        expect(find.text('Access denied'), findsOneWidget);
        expect(find.text('Cards'), findsNothing);
        expect(find.text('user@example.test'), findsNothing);
        await session.logout();
        await tester.pumpAndSettle();
        expect(find.text('Continue with Google'), findsOneWidget);
        expect(find.byType(NavigationRail), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        session.dispose();
      },
    );
  }
}
