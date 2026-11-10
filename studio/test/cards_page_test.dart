import 'package:biguess_studio/app/studio_theme.dart';
import 'package:biguess_studio/data/card_image.dart';
import 'package:biguess_studio/data/card_summary.dart';
import 'package:biguess_studio/data/dataset_store.dart';
import 'package:biguess_studio/data/pack_summary.dart';
import 'package:biguess_studio/data/studio_dataset.dart';
import 'package:biguess_studio/presentation/card_draft_dialog.dart';
import 'package:biguess_studio/presentation/cards_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'packs_page_test.dart' show PackUiController;
import 'topics_page_test.dart' show topicField;

const selectedPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGNkqHj2n4GBgYGJAQoAIyICYTlsIJwAAAAASUVORK5CYII=';

class CardUiController extends PackUiController {
  CardUiController({super.role});
  List<CardSummary> cardEntries = [
    const CardSummary(
      id: 'card-a',
      name: 'Ada Lovelace',
      imageReference: 'opaque-a',
      difficulty: 1,
      packId: 'owned',
      state: 'active',
      revision: 2,
      createdByUid: 'collector-a',
    ),
    const CardSummary(
      id: 'card-b',
      name: 'Other Pack identity',
      imageReference: 'opaque-b',
      difficulty: 2,
      packId: 'legacy',
      state: 'active',
      revision: 3,
      createdByUid: 'collector-b',
    ),
    const CardSummary(
      id: 'card-deleted',
      name: 'Deleted identity',
      imageReference: 'opaque-deleted',
      difficulty: 3,
      packId: 'owned',
      state: 'deleted',
      revision: 4,
      createdByUid: 'owner',
    ),
  ];
  @override
  List<CardSummary> get cards => cardEntries;
  @override
  List<PackSummary> get eligibleCardPacks =>
      packEntries.where((p) => {'active', 'hidden'}.contains(p.state)).toList();
  int cardCreates = 0;
  int cardEdits = 0;
  int cardHides = 0;
  int cardDeletes = 0;
  int cardRestores = 0;
  int cardPurges = 0;
  int cardQueues = 0;
  String? savedCardId;
  String? savedCardPack;
  String? savedCardName;
  int? savedCardDifficulty;
  CardImage? savedImage;
  void _saveCard() {
    if (failSave) throw const DatasetStorageFailure('quota-exceeded');
  }

  @override
  Future<void> createCardDraft({
    required String packId,
    required String name,
    required int difficulty,
    CardImage? image,
  }) async {
    _saveCard();
    cardCreates++;
    savedCardPack = packId;
    savedCardName = name;
    savedCardDifficulty = difficulty;
    savedImage = image;
  }

  @override
  Future<void> updateCard(
    String id, {
    required String name,
    required int difficulty,
    CardImage? image,
    int? expectedRevision,
  }) async {
    _saveCard();
    cardEdits++;
    savedCardId = id;
    savedCardName = name;
    savedCardDifficulty = difficulty;
    savedImage = image;
  }

  @override
  Future<void> updateCardDraft(
    String draftId, {
    required String packId,
    required String name,
    required int difficulty,
    CardImage? image,
  }) async {
    _saveCard();
    savedCardId = draftId;
    savedCardPack = packId;
    savedCardName = name;
    savedCardDifficulty = difficulty;
    savedImage = image;
  }

  @override
  Future<void> hideCard(String id, {int? expectedRevision}) async {
    cardHides++;
  }

  @override
  Future<void> deleteCard(String id, {int? expectedRevision}) async {
    cardDeletes++;
  }

  @override
  Future<void> restoreCard(String id, {int? expectedRevision}) async {
    cardRestores++;
  }

  @override
  Future<void> purgeCard(String id, {int? expectedRevision}) async {
    cardPurges++;
  }

  @override
  Future<void> queueDraft(String id) async {
    cardQueues++;
  }
}

void main() {
  late CardUiController controller;
  setUp(() => controller = CardUiController());
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
              child: CardsPage(controller: controller, initialPackId: 'owned'),
            ),
          ),
        ),
      );
  Future<void> editor(
    WidgetTester tester, {
    CardSummary? card,
    String filename = 'Grace_Hopper.png',
    Future<CardImage?> Function()? pickImage,
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
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => CardDraftDialog(
                  controller: controller,
                  packId: 'owned',
                  card: card,
                  pickImage:
                      pickImage ??
                      () async => CardImage(
                        filename: filename,
                        mimeType: 'image/png',
                        base64: selectedPng,
                      ),
                ),
              ),
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Card review is scoped by selected Pack ID and search stays local',
    (tester) async {
      await show(tester);
      expect(find.text('Ada Lovelace'), findsOneWidget);
      expect(find.text('Other Pack identity'), findsNothing);
      await tester.enterText(topicField('Search Cards'), 'missing');
      await tester.pump();
      expect(find.text('Ada Lovelace'), findsNothing);
      expect(controller.cardCreates + controller.cardEdits, 0);
    },
  );

  testWidgets(
    'New Card has only canonical fields and requires explicit local saving',
    (tester) async {
      await editor(tester);
      for (final field in [
        'Subtitle',
        'Description',
        'Tags',
        'Aliases',
        'Creator UID',
      ]) {
        expect(topicField(field), findsNothing);
      }
      await tester.tap(find.text('Save Card locally'));
      await tester.pumpAndSettle();
      expect(controller.cardCreates, 0);
      await tester.tap(find.text('Select image'));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == 'Selected image preview',
        ),
        findsOneWidget,
      );
      expect(find.text('Grace_Hopper.png'), findsOneWidget);
      final name = tester
          .widget<TextField>(topicField('Card name'))
          .controller!
          .text;
      expect(name, isNotEmpty);
      await tester.enterText(topicField('Card name'), 'Grace Hopper');
      expect(controller.cardCreates, 0);
      await tester.tap(find.text('Save Card locally'));
      await tester.pumpAndSettle();
      expect(controller.cardCreates, 1);
      expect(controller.savedCardPack, 'owned');
      expect(controller.savedCardName, 'Grace Hopper');
      expect(controller.savedCardDifficulty, inInclusiveRange(1, 3));
      expect(controller.savedImage?.filename, 'Grace_Hopper.png');
    },
  );

  testWidgets(
    'Filename suggestion preserves a manually entered name and difficulty is 1 through 3',
    (tester) async {
      await editor(tester);
      await tester.enterText(topicField('Card name'), 'Manual identity');
      await tester.tap(find.text('Select image'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(topicField('Card name')).controller!.text,
        'Manual identity',
      );
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('3 — Hard').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Card locally'));
      await tester.pumpAndSettle();
      expect(controller.savedCardDifficulty, 3);
    },
  );

  testWidgets('Replacing an image retains the canonical Card ID and name', (
    tester,
  ) async {
    await editor(tester, card: controller.cardEntries.first);
    await tester.tap(find.text('Replace image'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == 'Selected image preview',
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<TextField>(topicField('Card name')).controller!.text,
      'Ada Lovelace',
    );
    await tester.tap(find.text('Save Card locally'));
    await tester.pumpAndSettle();
    expect(controller.cardEdits, 1);
    expect(controller.savedCardId, 'card-a');
    expect(controller.savedImage?.filename, 'Grace_Hopper.png');
  });

  testWidgets(
    'Image picker failure retains existing identity and keyboard saving remains explicit',
    (tester) async {
      await editor(
        tester,
        card: controller.cardEntries.first,
        pickImage: () async => throw const FormatException('unsupported image'),
      );
      await tester.tap(find.text('Replace image'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Could not select that image'),
        findsOneWidget,
      );
      await tester.enterText(
        topicField('Card name'),
        'Keyboard edited identity',
      );
      expect(controller.cardEdits, 0);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(controller.cardEdits, 1);
      expect(controller.savedCardId, 'card-a');
      expect(controller.savedImage, isNull);
    },
  );

  testWidgets(
    'Collector can edit and hide but never sees Owner lifecycle controls or attribution',
    (tester) async {
      controller.dispose();
      controller = CardUiController(role: 'collector');
      controller.cardEntries = [controller.cardEntries.first];
      await show(tester);
      expect(find.text('Edit Card'), findsOneWidget);
      expect(find.text('Hide Card'), findsOneWidget);
      for (final action in [
        'Delete Card',
        'Restore Card',
        'Permanently delete Card',
      ]) {
        expect(find.text(action), findsNothing);
      }
      expect(find.textContaining('collector-a'), findsNothing);
      await tester.tap(find.text('Hide Card'));
      await tester.pumpAndSettle();
      expect(controller.cardHides, 1);
    },
  );

  testWidgets(
    'Owner Card deletion restoration and purge require confirmation and support cancellation',
    (tester) async {
      await show(tester);
      await tester.enterText(topicField('Search Cards'), 'Ada Lovelace');
      await tester.pump();
      await tester.tap(find.text('Delete Card'));
      await tester.pumpAndSettle();
      expect(controller.cardDeletes, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(controller.cardDeletes, 0);
      await tester.tap(find.text('Delete Card'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm local delete'));
      await tester.pumpAndSettle();
      expect(controller.cardDeletes, 1);
      await tester.enterText(topicField('Search Cards'), 'Deleted identity');
      await tester.pump();
      await tester.tap(find.text('Restore Card'));
      await tester.pumpAndSettle();
      expect(controller.cardRestores, 0);
      await tester.tap(find.text('Confirm local restore'));
      await tester.pumpAndSettle();
      expect(controller.cardRestores, 1);
      await tester.tap(find.text('Permanently delete Card'));
      await tester.pumpAndSettle();
      expect(controller.cardPurges, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(controller.cardPurges, 0);
      await tester.tap(find.text('Permanently delete Card'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm local permanently delete'));
      await tester.pumpAndSettle();
      expect(controller.cardPurges, 1);
    },
  );

  testWidgets(
    'Pending Card draft queues explicitly while conflicts only permit discard',
    (tester) async {
      controller.cardEntries = [
        CardSummary(
          id: 'card-a',
          name: 'Local Card',
          imageReference: 'opaque-a',
          difficulty: 2,
          packId: 'owned',
          state: 'active',
          revision: 2,
          pending: LocalDraft(
            id: 'draft-card-a',
            resourceType: 'card',
            resourceId: 'card-a',
            baseRevision: 2,
            value: {
              'name': 'Local Card',
              'packId': 'owned',
              'difficulty': 2,
              'imageReference': 'opaque-a',
            },
          ),
        ),
      ];
      await show(tester);
      expect(controller.cardQueues, 0);
      await tester.tap(find.text('Queue Card commit'));
      await tester.pumpAndSettle();
      expect(controller.cardQueues, 1);
      controller.cardEntries = [
        CardSummary(
          id: 'card-a',
          name: 'Local Card',
          imageReference: 'opaque-a',
          difficulty: 2,
          packId: 'owned',
          state: 'active',
          revision: 3,
          pending: LocalDraft(
            id: 'draft-card-a',
            resourceType: 'card',
            resourceId: 'card-a',
            baseRevision: 2,
            status: DraftStatus.conflict,
            value: {
              'name': 'Local Card',
              'packId': 'owned',
              'difficulty': 2,
              'imageReference': 'opaque-a',
            },
          ),
        ),
      ];
      controller.notifyListeners();
      await tester.pump();
      expect(find.text('Queue Card commit'), findsNothing);
      expect(find.text('Edit Card'), findsNothing);
      expect(find.text('Discard Card change'), findsOneWidget);
    },
  );

  testWidgets(
    'Quota failure retains selected image and text; role loss clears editor and review',
    (tester) async {
      await editor(tester, card: controller.cardEntries.first);
      await tester.enterText(
        topicField('Card name'),
        'Sensitive unsaved identity',
      );
      await tester.tap(find.text('Replace image'));
      await tester.pumpAndSettle();
      controller.failSave = true;
      await tester.tap(find.text('Save Card locally'));
      await tester.pumpAndSettle();
      expect(find.text('Sensitive unsaved identity'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == 'Selected image preview',
        ),
        findsOneWidget,
      );
      controller.clearAccount();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Sensitive unsaved identity'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == 'Selected image preview',
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Card form and review fit 360 pixel touch layout at 200 percent text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await show(tester, textScale: 2);
      expect(tester.takeException(), isNull);
      await editor(tester, textScale: 2);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
