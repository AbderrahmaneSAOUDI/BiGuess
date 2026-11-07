import 'package:biguess_studio/app/studio_app.dart';
import 'package:biguess_studio/app/studio_route.dart';
import 'package:biguess_studio/presentation/studio_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> open(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const StudioApp());
    await tester.pumpAndSettle();
  }

  testWidgets('desktop navigation and inert login', (tester) async {
    await open(tester, const Size(1440, 900));
    expect(find.byType(NavigationRail), findsOneWidget);
    for (final route in StudioRoute.destinations) {
      await tester.tap(find.text(route.label).first);
      await tester.pumpAndSettle();
      expect(find.text(route.label), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Sign-in is not available yet'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('narrow touch navigation and enlarged text do not overflow', (
    tester,
  ) async {
    await open(tester, const Size(320, 640));
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    for (final route in StudioRoute.destinations) {
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      final tile = find.widgetWithText(ListTile, route.label);
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsNothing);
      expect(find.text(route.label), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('large text adapts tablet and desktop navigation', (
    tester,
  ) async {
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    for (final size in [
      const Size(800, 600),
      const Size(1024, 768),
      const Size(1440, 900),
    ]) {
      await open(tester, size);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'viewport $size');
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byTooltip('Open navigation menu'), findsOneWidget);
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('keyboard can focus and activate navigation', (tester) async {
    await open(tester, const Size(1024, 768));
    for (var i = 0; i < 12; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      if (find.text('Topics').evaluate().length == 2) break;
    }
    expect(find.text('Topics'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('status states expose readable semantics', (tester) async {
    final semantics = tester.ensureSemantics();
    for (final kind in StudioStatusKind.values) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudioStatus(
              kind: kind,
              title: kind.name,
              message: 'No data is displayed.',
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text(kind.name), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('No data is displayed')),
        findsWidgets,
      );
      if (kind == StudioStatusKind.loading) {
        expect(find.bySemanticsLabel(RegExp('Loading')), findsWidgets);
      }
      expect(tester.takeException(), isNull);
    }
    semantics.dispose();
  });

  test('routes parse deep links and reject unknown paths', () async {
    const parser = StudioRouteParser();
    for (final route in StudioRoute.values) {
      expect(
        await parser.parseRouteInformation(
          RouteInformation(uri: Uri.parse(route.path)),
        ),
        route,
      );
      expect(parser.restoreRouteInformation(route).uri.path, route.path);
    }
    expect(StudioRoute.fromUri(Uri.parse('/')), StudioRoute.dashboard);
    expect(StudioRoute.fromUri(Uri.parse('/unknown')), StudioRoute.notFound);
  });

  testWidgets('browser route updates replace visible page', (tester) async {
    await open(tester, const Size(1280, 800));
    final router = tester.state<NavigatorState>(find.byType(Navigator));
    final delegate = Router.of(router.context).routerDelegate as StudioRouter;
    await delegate.setNewRoutePath(StudioRoute.cards);
    delegate.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Cards'), findsNWidgets(2));
  });
}
