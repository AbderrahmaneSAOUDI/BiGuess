import 'dart:async';

import 'package:biguess_studio/app/studio_theme.dart';
import 'package:biguess_studio/data/publication_api.dart';
import 'package:biguess_studio/data/dataset_store.dart';
import 'package:biguess_studio/presentation/publication_review_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'publication_api_test.dart' show publicationJson;
import 'topics_page_test.dart' show TopicUiController;

class _ReviewController extends TopicUiController {
  _ReviewController({super.role});
  var json = publicationJson();
  final actions = <String?>[];
  String? evidence;
  String? failure;
  Completer<PublicationReview>? delayed;
  @override
  Future<PublicationReview> reviewPublication(
    String resourceType,
    String id, {
    String? action,
    PublicationReview? expected,
    String? evidence,
  }) async {
    actions.add(action);
    this.evidence = evidence;
    if (failure != null) throw DatasetStorageFailure(failure!);
    if (action == 'publish') {
      json = {
        ...json,
        'pendingRequestId': 'request-one',
        'status': 'pending_operator',
      };
    }
    return delayed?.future ?? PublicationReview.fromJson(json);
  }
}

void main() {
  late _ReviewController controller;
  setUp(() => controller = _ReviewController());
  tearDown(() => controller.dispose());
  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: StudioTheme.light,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showPublicationReview(context, controller, 'pack', 'pack/id'),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Future<void> tapAction(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
  }

  testWidgets(
    'review and validate do not publish; explicit release remains pending',
    (tester) async {
      await show(tester);
      expect(controller.actions, [null]);
      expect(find.text('2 eligible Cards'), findsOneWidget);
      expect(find.textContaining('one · difficulty 1'), findsOneWidget);
      await tapAction(tester, 'Validate');
      await tester.pumpAndSettle();
      expect(controller.actions, [null, 'validate']);
      await tapAction(tester, 'Request validated release');
      await tester.pumpAndSettle();
      expect(controller.actions.last, 'publish');
      expect(find.textContaining('awaiting trusted operator'), findsOneWidget);
      expect(find.text('Not public'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Request validated release'),
      );
      expect(button.onPressed, isNull);
    },
  );

  testWidgets('Collector sees no approval actions and cannot initial publish', (
    tester,
  ) async {
    controller.dispose();
    controller = _ReviewController(role: 'collector')
      ..json = publicationJson(ownerApproved: false);
    await show(tester);
    expect(find.text('Approve reviewed rights'), findsNothing);
    expect(find.text('Approve initial publication'), findsNothing);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Request validated release'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('Owner must provide evidence before approving rights', (
    tester,
  ) async {
    await show(tester);
    await tapAction(tester, 'Approve reviewed rights');
    await tester.pumpAndSettle();
    expect(controller.actions, [null]);
    expect(find.text('Enter the rights evidence reference.'), findsOneWidget);
    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'permission-record-42');
    await tapAction(tester, 'Approve reviewed rights');
    await tester.pumpAndSettle();
    expect(controller.actions.last, 'approve-rights');
    expect(controller.evidence, 'permission-record-42');
  });

  testWidgets('stale action clears approval state until another review', (
    tester,
  ) async {
    await show(tester);
    controller.failure = 'publication-conflict';
    await tapAction(tester, 'Request validated release');
    await tester.pumpAndSettle();
    expect(find.textContaining('reviewed revision changed'), findsOneWidget);
    expect(find.text('Request validated release'), findsNothing);
  });

  testWidgets('account switch closes review and discards late result', (
    tester,
  ) async {
    await show(tester);
    controller.delayed = Completer<PublicationReview>();
    await tapAction(tester, 'Validate');
    await tester.pump();
    controller.clearAccount();
    await tester.pumpAndSettle();
    expect(find.byType(PublicationReviewDialog), findsNothing);
    controller.delayed!.complete(PublicationReview.fromJson(publicationJson()));
    await tester.pumpAndSettle();
    expect(find.byType(PublicationReviewDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('review fits narrow width with large text', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: StudioTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: PublicationReviewDialog(
            controller: controller,
            resourceType: 'pack',
            id: 'pack/id',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Pack publication review'), findsOneWidget);
  });
  testWidgets(
    'hidden previously published Pack requires a new Owner approval',
    (tester) async {
      controller.json = {
        ...publicationJson(ownerApproved: false),
        'publishedRevision': 2,
        'state': 'hidden',
      };
      await show(tester);
      expect(find.text('Approve publication'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Request validated release'),
      );
      expect(button.onPressed, isNull);
    },
  );
}
