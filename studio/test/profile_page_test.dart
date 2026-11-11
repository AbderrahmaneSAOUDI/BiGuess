import 'dart:async';

import 'package:biguess_studio/app/studio_theme.dart';
import 'package:biguess_studio/auth/studio_session.dart';
import 'package:biguess_studio/data/profile_api.dart';
import 'package:biguess_studio/data/profile_controller.dart';
import 'package:biguess_studio/presentation/profile_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'profile_api_test.dart' show profileJson;
import 'profile_controller_test.dart' show Identity, Authorization, Api;

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
  Future<void> show(
    WidgetTester tester, {
    bool authGate = false,
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: StudioTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ListenableBuilder(
                listenable: session,
                builder: (context, _) =>
                    authGate && session.phase != SessionPhase.authorized
                    ? const Text('Checking access')
                    : ProfilePage(controller: controller),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'identity/role are verified; rendering never fetches stats; explicit refresh survives auth gate',
    (tester) async {
      await show(tester, authGate: true);
      expect(find.text('Email: a@example.test'), findsOneWidget);
      expect(find.text('Role: Collector'), findsOneWidget);
      expect(api.calls, 0);
      final gate = Completer<ContributorProfile>();
      api.handler = (_, _) => gate.future;
      await tester.tap(find.text('Refresh profile'));
      await tester.pump();
      expect(api.calls, 1);
      gate.complete(ContributorProfile.fromJson(profileJson()));
      await tester.pumpAndSettle();
      expect(find.text('Packs created: 1'), findsOneWidget);
      expect(find.text('Your contributions'), findsOneWidget);
      expect(find.text('Contributors'), findsNothing);
      expect(find.text('Created · pack · pack-a'), findsOneWidget);
      session.rejectAuthorization('forbidden');
      await tester.pump();
      expect(find.text('Packs created: 1'), findsNothing);
      expect(controller.profile, isNull);
    },
  );

  testWidgets(
    'Owner sees contributors and manually scopes activity by contributor',
    (tester) async {
      authorization.role = 'owner_admin';
      await session.validate();
      String? selected;
      api.handler = (uid, _) async {
        selected = uid;
        return ContributorProfile.fromJson(
          profileJson(uid: 'a', role: 'owner_admin', contributorUid: uid),
        );
      };
      await show(tester);
      await tester.tap(find.text('Refresh profile'));
      await tester.pumpAndSettle();
      expect(find.text('All contributors'), findsOneWidget);
      await tester.ensureVisible(find.text('View contributor activity'));
      await tester.tap(find.text('View contributor activity'));
      await tester.pumpAndSettle();
      expect(selected, 'a');
      expect(find.text('Contributions by a'), findsOneWidget);
      expect(find.text('Role: Owner'), findsOneWidget);
    },
  );

  testWidgets(
    'profile fits narrow screens with enlarged text and paginates explicitly',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      api.handler = (_, cursor) async => ContributorProfile.fromJson(
        profileJson(
          next: cursor == null ? 'next-page' : null,
          id: cursor == null ? 'pack-a' : 'pack-next',
        ),
      );
      await show(tester, textScale: 2);
      await tester.tap(find.text('Refresh profile'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Load more activity'));
      await tester.tap(find.text('Load more activity'));
      await tester.pumpAndSettle();
      expect(controller.profile!.activity, hasLength(2));
      expect(api.calls, 2);
      expect(find.text('Load more activity'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
