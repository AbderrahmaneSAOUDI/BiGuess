import 'package:biguess_studio/app/studio_theme.dart';
import 'package:biguess_studio/data/dataset_store.dart';
import 'package:biguess_studio/data/pack_summary.dart';
import 'package:biguess_studio/data/studio_dataset.dart';
import 'package:biguess_studio/presentation/packs_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'topics_page_test.dart' show TopicUiController, topicField;

class PackUiController extends TopicUiController {
  PackUiController({super.role});
  List<PackSummary> packEntries = [
    const PackSummary(
      id: 'owned',
      name: 'Contributor Pack',
      topicId: 'active-topic',
      state: 'active',
      revision: 2,
      eligibleCardCount: 1,
      createdByUid: 'collector-a',
    ),
    const PackSummary(
      id: 'legacy',
      name: 'Legacy empty Pack',
      topicId: 'active-topic',
      state: 'active',
      revision: 1,
      eligibleCardCount: 0,
    ),
    const PackSummary(
      id: 'deleted',
      name: 'Deleted Pack',
      createdByUid: 'owner',
      topicId: 'active-topic',
      state: 'deleted',
      revision: 3,
      eligibleCardCount: 0,
    ),
  ];
  @override
  List<PackSummary> get packs => packEntries;
  int edits = 0;
  int packHides = 0;
  int packDeletes = 0;
  int packRestores = 0;
  int packPurges = 0;
  @override
  Future<void> updatePack(
    String id, {
    required String name,
    required String topicId,
    int? expectedRevision,
  }) async {
    if (failSave) throw const DatasetStorageFailure('quota-exceeded');
    edits++;
    packName = name;
    packTopic = topicId;
  }

  @override
  Future<void> hidePack(String id, {int? expectedRevision}) async {
    packHides++;
  }

  @override
  Future<void> deletePack(String id, {int? expectedRevision}) async {
    packDeletes++;
  }

  @override
  Future<void> restorePack(String id, {int? expectedRevision}) async {
    packRestores++;
  }

  @override
  Future<void> purgePack(String id, {int? expectedRevision}) async {
    packPurges++;
  }
}

void main() {
  late PackUiController controller;
  setUp(() => controller = PackUiController());
  tearDown(() => controller.dispose());
  Future<void> show(WidgetTester tester, {double textScale = 1}) =>
      tester.pumpWidget(
        MaterialApp(
          theme: StudioTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: PacksPage(controller: controller),
            ),
          ),
        ),
      );
  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(topicField('Search Packs'), query);
    await tester.pump();
  }

  testWidgets(
    'Owner global view includes attribution and unassigned empty legacy drafts',
    (tester) async {
      await show(tester);
      expect(find.text('Contributor Pack'), findsOneWidget);
      expect(find.text('Legacy empty Pack'), findsOneWidget);
      expect(find.text('Deleted Pack'), findsOneWidget);
      expect(find.textContaining('collector-a'), findsOneWidget);
      expect(find.textContaining('Unassigned legacy'), findsOneWidget);
      expect(find.textContaining('Draft'), findsWidgets);
    },
  );

  testWidgets(
    'Pack search is local; synchronized edits save explicitly and retain one Topic',
    (tester) async {
      await show(tester);
      await search(tester, 'contributor');
      expect(find.text('Legacy empty Pack'), findsNothing);
      expect(controller.edits, 0);
      await tester.tap(find.text('Edit Pack'));
      await tester.pumpAndSettle();
      await tester.enterText(topicField('Pack name'), 'Changed name');
      expect(controller.edits, 0);
      await tester.tap(find.text('Save Pack draft locally'));
      await tester.pumpAndSettle();
      expect(controller.edits, 1);
      expect(controller.packName, 'Changed name');
      expect(controller.packTopic, 'active-topic');
    },
  );

  testWidgets(
    'Owner delete restore and permanent deletion require confirmation with cancellation',
    (tester) async {
      await show(tester);
      await search(tester, 'Contributor Pack');
      await tester.tap(find.text('Delete Pack'));
      await tester.pumpAndSettle();
      expect(controller.packDeletes, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(controller.packDeletes, 0);
      await tester.tap(find.text('Delete Pack'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm local delete'));
      await tester.pumpAndSettle();
      expect(controller.packDeletes, 1);
      await search(tester, 'Deleted Pack');
      await tester.tap(find.text('Restore Pack'));
      await tester.pumpAndSettle();
      expect(controller.packRestores, 0);
      await tester.tap(find.text('Confirm local restore'));
      await tester.pumpAndSettle();
      expect(controller.packRestores, 1);
      await tester.tap(find.text('Permanently delete Pack'));
      await tester.pumpAndSettle();
      expect(controller.packPurges, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(controller.packPurges, 0);
      await tester.tap(find.text('Permanently delete Pack'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm local permanently delete'));
      await tester.pumpAndSettle();
      expect(controller.packPurges, 1);
    },
  );

  testWidgets(
    'Collector has edit hide and independent creation but no Owner destruction or attribution',
    (tester) async {
      controller.dispose();
      controller = PackUiController(role: 'collector');
      controller.packEntries = [controller.packEntries.first];
      await show(tester);
      expect(find.text('New Pack draft'), findsOneWidget);
      expect(find.text('Edit Pack'), findsOneWidget);
      expect(find.text('Hide Pack'), findsOneWidget);
      for (final label in [
        'Delete Pack',
        'Restore Pack',
        'Permanently delete Pack',
      ]) {
        expect(find.text(label), findsNothing);
      }
      expect(find.textContaining('collector-a'), findsNothing);
      await tester.tap(find.text('Hide Pack'));
      await tester.pumpAndSettle();
      expect(controller.packHides, 1);
    },
  );

  testWidgets(
    'Pending Pack statuses show explicit queue and conflicts prevent edit and queue',
    (tester) async {
      controller.packEntries = [
        PackSummary(
          id: 'owned',
          name: 'Pending Pack',
          topicId: 'active-topic',
          state: 'active',
          revision: 2,
          eligibleCardCount: 0,
          pending: LocalDraft(
            id: 'pack-draft',
            resourceType: 'pack',
            resourceId: 'owned',
            baseRevision: 2,
            value: {'name': 'Pending Pack', 'topicId': 'active-topic'},
          ),
        ),
      ];
      await show(tester);
      expect(find.text('Draft — saved locally'), findsOneWidget);
      expect(controller.queues, 0);
      await tester.tap(find.text('Queue commit'));
      await tester.pumpAndSettle();
      expect(controller.queues, 1);
      controller.packEntries = [
        PackSummary(
          id: 'owned',
          name: 'Pending Pack',
          topicId: 'active-topic',
          state: 'active',
          revision: 3,
          eligibleCardCount: 0,
          pending: LocalDraft(
            id: 'pack-draft',
            resourceType: 'pack',
            resourceId: 'owned',
            baseRevision: 2,
            status: DraftStatus.conflict,
            value: {'name': 'Pending Pack', 'topicId': 'active-topic'},
          ),
        ),
      ];
      controller.notifyListeners();
      await tester.pump();
      expect(find.text('Queue commit'), findsNothing);
      expect(find.text('Edit Pack'), findsNothing);
      expect(find.text('Discard local change'), findsOneWidget);
    },
  );

  testWidgets(
    'Pack quota failure retains text and account loss closes sensitive modal',
    (tester) async {
      await show(tester);
      await search(tester, 'Contributor Pack');
      await tester.tap(find.text('Edit Pack'));
      await tester.pumpAndSettle();
      await tester.enterText(topicField('Pack name'), 'Sensitive unsaved Pack');
      controller.failSave = true;
      await tester.tap(find.text('Save Pack draft locally'));
      await tester.pumpAndSettle();
      expect(find.text('Sensitive unsaved Pack'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      controller.clearAccount();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Sensitive unsaved Pack'), findsNothing);
    },
  );

  testWidgets(
    'Status filtering separates empty drafts and synchronized lifecycle states',
    (tester) async {
      await show(tester);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Drafts').last);
      await tester.pumpAndSettle();
      expect(find.text('Contributor Pack'), findsNothing);
      expect(find.text('Legacy empty Pack'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Deleted').last);
      await tester.pumpAndSettle();
      expect(find.text('Legacy empty Pack'), findsNothing);
      expect(find.text('Deleted Pack'), findsOneWidget);
      expect(controller.edits + controller.packDeletes, 0);
    },
  );

  testWidgets('Keyboard Enter explicitly saves a synchronized Pack name', (
    tester,
  ) async {
    await show(tester);
    await search(tester, 'Contributor Pack');
    await tester.tap(find.text('Edit Pack'));
    await tester.pumpAndSettle();
    await tester.enterText(topicField('Pack name'), 'Keyboard submitted Pack');
    expect(controller.edits, 0);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(controller.edits, 1);
    expect(controller.packName, 'Keyboard submitted Pack');
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('Pack list and dialog fit touch width at 200 percent text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await show(tester, textScale: 2);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('New Pack draft'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
