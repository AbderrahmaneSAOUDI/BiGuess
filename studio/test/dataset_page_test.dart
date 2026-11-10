import 'package:biguess_studio/app/studio_route.dart';
import 'package:biguess_studio/app/studio_theme.dart';
import 'package:biguess_studio/data/dataset_controller.dart';
import 'package:biguess_studio/data/dataset_store.dart';
import 'package:biguess_studio/data/studio_dataset.dart';
import 'package:biguess_studio/presentation/dataset_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Controller extends ChangeNotifier implements DatasetController {
  @override
  DatasetScope? scope = const DatasetScope('project', 'a', 'collector');
  @override
  DatasetSnapshot? snapshot;
  @override
  DatasetPhase phase = DatasetPhase.offline;
  @override
  String? errorCode;
  bool failSave = false;
  int saves = 0;
  @override
  bool get busy => false;
  @override
  Future<void> refresh() async {}
  @override
  Future<void> retryStorage() async {}
  @override
  Future<void> saveDraft(
    Map<String, Object?> record, {
    required String name,
  }) async {
    if (failSave) throw const DatasetStorageFailure('quota');
    saves++;
    snapshot = snapshot!.copyWith(
      drafts: [
        LocalDraft(
          id: 'name-a',
          resourceType: 'pack',
          resourceId: 'pack-a',
          baseRevision: 1,
          value: {...record, 'name': name},
        ),
      ],
    );
    notifyListeners();
  }

  @override
  Future<void> queueDraft(String draftId) async {
    snapshot = snapshot!.copyWith(
      drafts: snapshot!.drafts
          .map((draft) => draft.copyWith(status: DraftStatus.unsent))
          .toList(),
    );
    notifyListeners();
  }

  @override
  Future<void> discardDraft(String draftId) async {}

  void clearAccount() {
    scope = null;
    snapshot = null;
    phase = DatasetPhase.idle;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Controller controller;
  setUp(() {
    controller = _Controller();
    controller.snapshot = DatasetSnapshot(
      scope: controller.scope!,
      lastSyncedAt: DateTime.utc(2026, 11, 10),
      records: [
        {
          'resourceType': 'pack',
          'id': 'pack-a',
          'name': 'Private A',
          'topicId': 'topic',
          'state': 'active',
          'revision': 1,
        },
      ],
    );
  });
  tearDown(() => controller.dispose());

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: StudioTheme.light,
        home: Scaffold(
          body: SingleChildScrollView(
            child: DatasetPage(
              route: StudioRoute.myPacks,
              controller: controller,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('offline local editor retains unsaved text on quota failure', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.text('Edit name locally'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Offline name');
    controller.failSave = true;
    await tester.tap(find.text('Save locally'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not save locally.'), findsOneWidget);
    expect(find.text('Offline name'), findsOneWidget);
    expect(controller.saves, 0);
    controller.failSave = false;
    await tester.tap(find.text('Save locally'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Draft — saved locally'), findsOneWidget);
    expect(find.textContaining('Published revision: unknown'), findsOneWidget);
    await tester.ensureVisible(find.text('Queue commit'));
    await tester.tap(find.text('Queue commit'));
    await tester.pumpAndSettle();
    expect(find.text('Unsent commit — queued locally'), findsOneWidget);
  });

  testWidgets('account closure dismisses an editor and removes private text', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.text('Edit name locally'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Unsent A name');
    controller.clearAccount();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Private A'), findsNothing);
    expect(find.text('Unsent A name'), findsNothing);
    expect(controller.saves, 0);
  });
}
