import 'package:biguess_studio/app/studio_theme.dart';
import 'package:biguess_studio/data/dataset_controller.dart';
import 'package:biguess_studio/data/dataset_store.dart';
import 'package:biguess_studio/data/studio_dataset.dart';
import 'package:biguess_studio/data/topic_taxonomy.dart';
import 'package:biguess_studio/presentation/topics_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class TopicUiController extends ChangeNotifier implements DatasetController {
  TopicUiController({String role = 'owner_admin'})
    : scope = DatasetScope('project', 'account', role) {
    snapshot = DatasetSnapshot(scope: scope!, records: const []);
  }
  @override
  DatasetScope? scope;
  @override
  late DatasetSnapshot? snapshot;
  @override
  DatasetPhase phase = DatasetPhase.ready;
  @override
  bool get busy => false;
  @override
  String? errorCode;
  List<TopicTaxonomy> entries = [
    const TopicTaxonomy(
      id: 'active-topic',
      name: 'Active taxonomy',
      state: 'active',
      revision: 2,
    ),
    const TopicTaxonomy(
      id: 'deleted-topic',
      name: 'Deleted taxonomy',
      state: 'deleted',
      revision: 3,
    ),
  ];
  bool failSave = false;
  int creates = 0;
  int renames = 0;
  int hides = 0;
  int deletes = 0;
  int restores = 0;
  int queues = 0;
  String? packName;
  String? packTopic;
  @override
  List<TopicTaxonomy> get topics => entries;
  @override
  List<TopicTaxonomy> get eligibleTopics =>
      entries.where((topic) => topic.eligible).toList();
  void _save() {
    if (failSave) throw const DatasetStorageFailure('quota-exceeded');
  }

  @override
  Future<void> createTopic(String name) async {
    _save();
    creates++;
  }

  @override
  Future<void> renameTopic(String id, String name) async {
    _save();
    renames++;
  }

  @override
  Future<void> hideTopic(String id) async {
    _save();
    hides++;
  }

  @override
  Future<void> deleteTopic(String id) async {
    _save();
    deletes++;
  }

  @override
  Future<void> restoreTopic(String id) async {
    _save();
    restores++;
  }

  @override
  Future<void> queueDraft(String id) async {
    _save();
    queues++;
  }

  @override
  Future<void> discardDraft(String id) async {
    _save();
  }

  @override
  Future<void> createPackDraft({
    required String name,
    required String topicId,
  }) async {
    _save();
    packName = name;
    packTopic = topicId;
  }

  @override
  Future<void> updatePackDraft(
    String draftId, {
    required String name,
    required String topicId,
  }) async {
    _save();
    packName = name;
    packTopic = topicId;
  }

  void clearAccount() {
    scope = null;
    snapshot = null;
    phase = DatasetPhase.idle;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Finder topicField(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

void main() {
  late TopicUiController controller;
  setUp(() => controller = TopicUiController());
  tearDown(() => controller.dispose());
  Future<void> show(WidgetTester tester) async => tester.pumpWidget(
    MaterialApp(
      theme: StudioTheme.light,
      home: Scaffold(
        body: SingleChildScrollView(child: TopicsPage(controller: controller)),
      ),
    ),
  );

  testWidgets(
    'Owner search is local and create/rename save only on explicit action',
    (tester) async {
      await show(tester);
      await tester.enterText(topicField('Search Topics'), 'ACTIVE');
      await tester.pump();
      expect(find.text('Active taxonomy'), findsOneWidget);
      expect(find.text('Deleted taxonomy'), findsNothing);
      expect(controller.creates, 0);
      expect(controller.renames, 0);
      await tester.tap(find.text('Rename Topic'));
      await tester.pumpAndSettle();
      await tester.enterText(topicField('Topic name'), 'Renamed locally');
      expect(controller.renames, 0);
      await tester.tap(find.text('Save Topic locally'));
      await tester.pumpAndSettle();
      expect(controller.renames, 1);
      await tester.tap(find.text('New Topic'));
      await tester.pumpAndSettle();
      await tester.enterText(topicField('Topic name'), 'New local taxonomy');
      expect(controller.creates, 0);
      await tester.tap(find.text('Save Topic locally'));
      await tester.pumpAndSettle();
      expect(controller.creates, 1);
    },
  );

  testWidgets(
    'Owner delete and restore require destructive confirmation; hide stays local',
    (tester) async {
      await show(tester);
      await tester.enterText(topicField('Search Topics'), 'active taxonomy');
      await tester.pump();
      await tester.tap(find.text('Hide Topic'));
      await tester.pumpAndSettle();
      expect(controller.hides, 1);
      await tester.tap(find.text('Delete Topic'));
      await tester.pumpAndSettle();
      expect(controller.deletes, 0);
      expect(find.textContaining('contained Packs and Cards'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(controller.deletes, 0);
      await tester.tap(find.text('Delete Topic'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save deletion locally'));
      await tester.pumpAndSettle();
      expect(controller.deletes, 1);
      await tester.enterText(topicField('Search Topics'), 'deleted taxonomy');
      await tester.pump();
      await tester.tap(find.text('Restore Topic'));
      await tester.pumpAndSettle();
      expect(controller.restores, 0);
      expect(find.textContaining('hidden state'), findsOneWidget);
      await tester.tap(find.text('Save restoration locally'));
      await tester.pumpAndSettle();
      expect(controller.restores, 1);
    },
  );

  testWidgets(
    'Collector sees minimal nondeleted taxonomy with no Owner mutation controls',
    (tester) async {
      controller.dispose();
      controller = TopicUiController(role: 'collector');
      await show(tester);
      expect(find.text('Active taxonomy'), findsOneWidget);
      expect(find.text('Deleted taxonomy'), findsNothing);
      for (final label in [
        'New Topic',
        'Rename Topic',
        'Hide Topic',
        'Delete Topic',
        'Restore Topic',
        'Queue Topic commit',
      ]) {
        expect(find.text(label), findsNothing);
      }
      expect(find.textContaining('createdByUid'), findsNothing);
      expect(
        controller.creates +
            controller.renames +
            controller.hides +
            controller.deletes +
            controller.restores,
        0,
      );
    },
  );

  testWidgets(
    'pending actions have distinct statuses and require explicit queueing',
    (tester) async {
      controller.entries = [
        TopicTaxonomy(
          id: 'active-topic',
          name: 'Changed taxonomy',
          state: 'active',
          revision: 2,
          pending: LocalDraft(
            id: 'pending',
            resourceType: 'topic',
            resourceId: 'active-topic',
            value: {'name': 'Changed taxonomy'},
            baseRevision: 2,
            action: 'update',
          ),
        ),
      ];
      await show(tester);
      expect(find.textContaining('Draft — saved locally'), findsOneWidget);
      expect(controller.queues, 0);
      expect(find.text('Delete Topic'), findsNothing);
      await tester.tap(find.text('Queue Topic commit'));
      await tester.pumpAndSettle();
      expect(controller.queues, 1);
    },
  );

  testWidgets(
    'quota failure retains Topic form text and scope loss clears the modal and search',
    (tester) async {
      await show(tester);
      await tester.enterText(topicField('Search Topics'), 'private search');
      await tester.pump();
      await tester.tap(find.text('New Topic'));
      await tester.pumpAndSettle();
      await tester.enterText(
        topicField('Topic name'),
        'Unsaved private taxonomy',
      );
      controller.failSave = true;
      await tester.tap(find.text('Save Topic locally'));
      await tester.pumpAndSettle();
      expect(find.text('Unsaved private taxonomy'), findsOneWidget);
      expect(find.textContaining('Browser storage is full'), findsOneWidget);
      controller.clearAccount();
      await tester.pumpAndSettle();
      expect(find.text('Unsaved private taxonomy'), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('private search'), findsNothing);
    },
  );

  testWidgets('Topic list and name form fit a narrow screen at large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: StudioTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: TopicsPage(controller: controller),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('New Topic'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
