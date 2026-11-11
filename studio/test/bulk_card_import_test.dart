import 'dart:async';

import 'package:biguess_studio/app/studio_theme.dart';
import 'package:biguess_studio/data/bulk_card_import.dart';
import 'package:biguess_studio/data/card_image.dart';
import 'package:biguess_studio/data/dataset_api.dart';
import 'package:biguess_studio/data/dataset_store.dart';
import 'package:biguess_studio/data/image_ingestion.dart';
import 'package:biguess_studio/data/studio_dataset.dart';
import 'package:biguess_studio/presentation/bulk_card_import_page.dart';
import 'package:biguess_studio/presentation/cards_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cards_page_test.dart' show CardUiController;
import 'image_preparation_page_test.dart' show ControlledSource, preparedPixel;

class MockBulkController extends CardUiController {
  MockBulkController({super.role});

  int _cardIdCounter = 0;
  @override
  String newCardId() => 'mock-card-${++_cardIdCounter}';

  final savedBulkItems = <BulkImportItem>[];
  final committedBulkItems = <BulkImportItem>[];
  final hiddenCardIds = <String>[];
  final difficultyUpdatedCardIds = <String>[];
  final deletedCardIds = <String>[];
  int? lastUpdatedDifficulty;
  bool failBulkCommit = false;
  bool failUpload = false;
  String? bulkErrorMessage;

  @override
  Future<void> saveBulkCardDrafts({
    required String packId,
    required List<BulkImportItem> items,
  }) async {
    if (failSave) throw const DatasetStorageFailure('quota-exceeded');
    savedBulkItems.addAll(items);
  }

  @override
  Future<BulkImportResult> importAndCommitBulkCards({
    required String packId,
    required List<BulkImportItem> items,
    void Function(BulkImportProgress)? onProgress,
    Future<void>? cancelled,
  }) async {
    if (failUpload) throw const DatasetStorageFailure('image-quota');
    if (failBulkCommit) throw const DatasetStorageFailure('draft-conflict');
    committedBulkItems.addAll(items);
    onProgress?.call(
      const BulkImportProgress(stage: 'committing', current: 1, total: 1),
    );
    return BulkImportResult(
      committedCount: items.length,
      batchCount: (items.length / 100).ceil(),
      finalRevision: 2,
    );
  }

  @override
  Future<void> bulkHideCards(List<String> cardIds) async {
    hiddenCardIds.addAll(cardIds);
  }

  @override
  Future<void> bulkUpdateDifficulty(
    List<String> cardIds,
    int newDifficulty,
  ) async {
    difficultyUpdatedCardIds.addAll(cardIds);
    lastUpdatedDifficulty = newDifficulty;
  }

  @override
  Future<void> bulkDeleteCards(List<String> cardIds) async {
    if (scope?.role != 'owner_admin') {
      throw const DatasetStorageFailure('forbidden');
    }
    deletedCardIds.addAll(cardIds);
  }
}

class TestImageIngestion implements ImageIngestionApi {
  int uploadCalls = 0;
  bool failQuota = false;
  bool failConnection = false;
  final uploadedHashes = <String>{};

  @override
  Future<UploadedCardImage> upload(
    String token,
    String packId,
    int revision,
    CardImage image,
    bool Function() current, {
    required Future<void> cancelled,
  }) async {
    uploadCalls++;
    if (failQuota) throw const DatasetApiFailure('image-quota');
    if (failConnection) {
      throw const DatasetApiFailure('image-upload-unavailable');
    }
    final sha256 = image.preparation?.sha256 ?? ('0' * 64);
    uploadedHashes.add(sha256);
    return UploadedCardImage(
      packId: packId,
      imageReference: 'objects/$sha256.png',
      sha256: sha256,
      byteLength: image.bytes.length,
      contentType: 'image/png',
      width: image.preparation?.width ?? 2,
      height: image.preparation?.height ?? 2,
    );
  }

  @override
  void close() {}
}

class TestDatasetApi implements DatasetApi {
  int commitCalls = 0;
  bool failConflict = false;
  final committedBatches = <Map<String, Object?>>[];
  final idempotencyKeys = <String>[];
  final revisions = <int>[];

  @override
  Future<InitialDataset> initial(String token, bool Function() current) async =>
      const InitialDataset([], 'resume');

  @override
  Future<BatchCommitResult> commitBatch(
    String token, {
    required String idempotencyKey,
    required int revision,
    required Map<String, Object?> batch,
    required bool Function() current,
  }) async {
    commitCalls++;
    idempotencyKeys.add(idempotencyKey);
    revisions.add(revision);
    committedBatches.add(batch);
    if (failConflict) throw const DatasetApiFailure('draft-conflict');
    return BatchCommitResult(
      revision: revision + 1,
      committedAt: DateTime.now().toUtc().toIso8601String(),
      actorId: token.split('-').last,
    );
  }

  @override
  void close() {}
}

class MemoryDatasetStore implements DatasetStore {
  DatasetSnapshot? stored;
  @override
  Future<void> authorize(DatasetScope scope) async {}
  @override
  Future<void> revoke(String project, String uid) async {}
  @override
  Future<DatasetScope?> offlineScope(String project, String uid) async => null;
  @override
  Future<DatasetSnapshot?> read(DatasetScope scope) async => stored;
  @override
  Future<DatasetSnapshot> save(
    DatasetSnapshot candidate, {
    int? expectedVersion,
  }) async {
    stored = candidate.copyWith(version: (expectedVersion ?? 0) + 1);
    return stored!;
  }

  @override
  void close() {}
}

extension StringRepeat on String {
  String repeat(int n) => List.filled(n, this).join();
}

void main() {
  group('BulkCardImport models', () {
    test('BulkImportItem validates name and difficulty', () {
      final img = preparedPixel('test.png');
      final valid = BulkImportItem(
        id: 'c1',
        sourceFilename: 'test.png',
        name: 'Valid Name',
        difficulty: 2,
        image: img,
      );
      expect(valid.isValid, isTrue);
      expect(valid.validationError, isNull);

      final emptyName = BulkImportItem(
        id: 'c2',
        sourceFilename: 'test.png',
        name: '   ',
        difficulty: 2,
        image: img,
      );
      expect(emptyName.isValid, isFalse);
      expect(emptyName.validationError, contains('Name'));

      final badDiff = BulkImportItem(
        id: 'c3',
        sourceFilename: 'test.png',
        name: 'Valid',
        difficulty: 4,
        image: img,
      );
      expect(badDiff.isValid, isFalse);
      expect(badDiff.validationError, contains('Difficulty'));
    });

    test('BulkImportProgress computes fraction correctly', () {
      const p1 = BulkImportProgress(stage: 'preparing', current: 5, total: 10);
      expect(p1.fraction, 0.5);

      const p2 = BulkImportProgress(stage: 'uploading', current: 0, total: 0);
      expect(p2.fraction, 0.0);
    });
  });

  group('BulkCardImportPage widget tests', () {
    testWidgets(
      'renders desktop table with per-row editing, duplicate detection and reload warning',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final controller = MockBulkController();
        final sources = [
          ControlledSource(
            'Ada_Lovelace.png',
            output: preparedPixel('Ada_Lovelace.png'),
          ),
          ControlledSource(
            'Grace_Hopper.png',
            output: preparedPixel('Grace_Hopper.png', red: true),
          ),
          ControlledSource(
            'Duplicate_Ada.png',
            output: preparedPixel('Ada_Lovelace.png'),
          ), // same sha256 as first
        ];

        await tester.pumpWidget(
          MaterialApp(
            theme: StudioTheme.light,
            home: Scaffold(
              body: BulkCardImportPage(
                controller: controller,
                packId: 'owned',
                pickSources: () async => sources,
              ),
            ),
          ),
        );

        expect(find.text('Bulk import Cards'), findsOneWidget);
        expect(find.text('Pack: owned'), findsOneWidget);
        expect(
          find.textContaining('cannot be recovered across browser reload'),
          findsOneWidget,
        );

        // Trigger selection
        await tester.tap(find.text('Select images'));
        await tester.pump();
        await tester.pumpAndSettle();

        // 3 items imported
        expect(find.text('Card Name'), findsOneWidget);
        expect(find.text('Difficulty'), findsOneWidget);
        expect(find.text('Duplicate'), findsOneWidget);
        expect(find.text('2 ready · 1 duplicates · 0 invalid'), findsOneWidget);

        // Verify desktop table cells
        expect(find.text('Ada Lovelace'), findsNWidgets(2));
        expect(find.text('Grace Hopper'), findsOneWidget);

        // Save as local drafts
        await tester.tap(find.text('Save as local drafts'));
        await tester.pump();
        expect(controller.savedBulkItems.length, 3);
        expect(
          find.textContaining('Saved 3 Card drafts locally'),
          findsOneWidget,
        );

        // Commit all
        await tester.tap(find.text('Upload & Commit Cards'));
        await tester.pump();
        expect(controller.committedBulkItems.length, 3);
        expect(find.textContaining('Committed 3 Cards'), findsOneWidget);
      },
    );

    testWidgets(
      'renders narrow-screen list layout below 680px with removal and difficulty edit',
      (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final controller = MockBulkController();
        final sources = [
          ControlledSource(
            'Ada_Lovelace.png',
            output: preparedPixel('Ada_Lovelace.png'),
          ),
        ];

        await tester.pumpWidget(
          MaterialApp(
            theme: StudioTheme.light,
            home: Scaffold(
              body: BulkCardImportPage(
                controller: controller,
                packId: 'owned',
                pickSources: () async => sources,
              ),
            ),
          ),
        );

        await tester.tap(find.text('Select images'));
        await tester.pump();
        await tester.pumpAndSettle();

        expect(find.text('Ada_Lovelace.png'), findsOneWidget);
        expect(find.text('Card Name'), findsOneWidget);

        // Remove item
        await tester.tap(find.byTooltip('Remove Ada Lovelace'));
        await tester.pump();

        expect(find.text('Ada_Lovelace.png'), findsNothing);
        expect(find.text('0 ready · 0 duplicates · 0 invalid'), findsNothing);
      },
    );

    testWidgets('cancellation cleanly stops preparation', (tester) async {
      final controller = MockBulkController();
      final pending = Completer<CardImage>();
      final sources = [
        ControlledSource('Slow_Image.png', output: null)
          ..pending.complete(pending.future),
      ];

      await tester.pumpWidget(
        MaterialApp(
          theme: StudioTheme.light,
          home: Scaffold(
            body: BulkCardImportPage(
              controller: controller,
              packId: 'owned',
              pickSources: () async => sources,
            ),
          ),
        ),
      );

      await tester.tap(find.text('Select images'));
      await tester.pump();

      expect(find.text('Cancel operation'), findsOneWidget);
      await tester.tap(find.text('Cancel operation'));
      await tester.pump();

      expect(find.text('Cancel operation'), findsNothing);
    });
  });

  group('CardsPage bulk operations widget tests', () {
    testWidgets(
      'bulk multi-selection allows hide, change difficulty, and owner-only delete',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final ownerController = MockBulkController(role: 'owner_admin');
        await tester.pumpWidget(
          MaterialApp(
            theme: StudioTheme.light,
            home: Scaffold(
              body: SingleChildScrollView(
                child: CardsPage(
                  controller: ownerController,
                  initialPackId: 'owned',
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        // "Bulk import Cards" button is present
        expect(find.text('Bulk import Cards'), findsOneWidget);

        // Check "Select all"
        expect(find.text('Select all'), findsOneWidget);
        await tester.tap(find.text('Select all'));
        await tester.pump();

        // 2 cards in 'owned' pack: 'Ada Lovelace' and 'Deleted identity'
        expect(find.textContaining('selected'), findsWidgets);
        expect(find.text('Hide selected'), findsOneWidget);
        expect(find.text('Change difficulty'), findsOneWidget);
        expect(
          find.text('Delete selected'),
          findsOneWidget,
        ); // Owner can see delete

        // Bulk hide
        await tester.tap(find.text('Hide selected'));
        await tester.pump();
        expect(ownerController.hiddenCardIds.length, 2);

        // Re-select all and test difficulty
        await tester.tap(find.text('Select all'));
        await tester.pump();
        await tester.tap(find.text('Change difficulty'));
        await tester.pumpAndSettle();
        expect(find.text('3 (Hard)'), findsOneWidget);
        await tester.tap(find.text('3 (Hard)'));
        await tester.pumpAndSettle();
        expect(ownerController.difficultyUpdatedCardIds.length, 2);
        expect(ownerController.lastUpdatedDifficulty, 3);

        // Re-select all and test delete confirmation
        await tester.tap(find.text('Select all'));
        await tester.pump();
        await tester.tap(find.text('Delete selected'));
        await tester.pumpAndSettle();
        expect(find.text('Delete selected Cards'), findsOneWidget);
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        expect(ownerController.deletedCardIds.length, 2);
      },
    );

    testWidgets('Collector cannot see or perform bulk delete', (tester) async {
      final collectorController = MockBulkController(role: 'collector');
      await tester.pumpWidget(
        MaterialApp(
          theme: StudioTheme.light,
          home: Scaffold(
            body: SingleChildScrollView(
              child: CardsPage(
                controller: collectorController,
                initialPackId: 'owned',
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Select all'));
      await tester.pump();

      expect(find.text('Hide selected'), findsOneWidget);
      expect(find.text('Change difficulty'), findsOneWidget);
      expect(
        find.text('Delete selected'),
        findsNothing,
      ); // Collector CANNOT see bulk delete!
    });
  });
}
