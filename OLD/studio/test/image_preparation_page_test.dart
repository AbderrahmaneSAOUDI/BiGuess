import 'dart:async';

import 'package:biguess_studio/app/studio_theme.dart';
import 'package:biguess_studio/data/card_image.dart';
import 'package:biguess_studio/data/card_summary.dart';
import 'package:biguess_studio/data/image_preparation.dart';
import 'package:biguess_studio/data/studio_dataset.dart';
import 'package:biguess_studio/presentation/card_draft_dialog.dart';
import 'package:biguess_studio/presentation/image_preparation_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cards_page_test.dart' show CardUiController, selectedPng;
import 'topics_page_test.dart' show topicField;

const redPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGN8psHwn4GBgYGJAQoAH+4CEZZyVGYAAAAASUVORK5CYII=';
CardImage preparedPixel(String filename, {bool red = false}) => CardImage(
  filename: filename,
  mimeType: 'image/png',
  base64: red ? redPng : selectedPng,
  preparation: ImagePreparationInfo(
    sha256: red
        ? '0fa2fd104e8844cdb01389323b7884ce89f6c3135230e3f499dac3c6b632b19c'
        : '28e2c5feee64c1c1a0bdc757a79db4a538c71079970c1259e9d3493ff0a93b89',
    width: 2,
    height: 2,
  ),
);

class ControlledSource implements ImagePreparationSource {
  ControlledSource(this.filename, {this.output, this.error});
  @override
  final String filename;
  @override
  int get size => 100;
  final CardImage? output;
  final Object? error;
  final pending = Completer<CardImage>();
  int calls = 0;
  int disposals = 0;
  ImagePreparationCancellation? cancellation;
  void Function(ImagePreparationProgress)? progress;
  @override
  Future<CardImage> prepare({
    void Function(ImagePreparationProgress)? onProgress,
    ImagePreparationCancellation? cancellation,
  }) async {
    calls++;
    this.cancellation = cancellation;
    progress = onProgress;
    if (error != null) throw error!;
    if (output != null) return output!;
    return pending.future;
  }

  @override
  void dispose() {
    disposals++;
  }
}

Finder preview() => find.byWidgetPredicate(
  (widget) =>
      widget is Semantics &&
      widget.properties.label == 'Current prepared image preview',
);

void main() {
  late CardUiController controller;
  setUp(() => controller = CardUiController());
  tearDown(() => controller.dispose());
  Future<void> show(
    WidgetTester tester,
    List<ImagePreparationSource> sources, {
    VoidCallback? onClose,
    Future<List<ImagePreparationSource>> Function()? pickSources,
    double scale = 1,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: StudioTheme.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: ImagePreparationPage(
            controller: controller,
            packId: 'owned',
            pickSources: pickSources ?? () async => sources,
            onClose: onClose,
          ),
        ),
      ),
    ),
  );
  Future<void> start(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Select images'));
    await tester.tap(find.text('Select images'));
    await tester.pump();
  }

  testWidgets(
    'Batch preparation loads one source at a time, reports progress and keeps one preview',
    (tester) async {
      final first = ControlledSource('first.png');
      final second = ControlledSource('second.png');
      await show(tester, [first, second]);
      await start(tester);
      expect(first.calls, 1);
      expect(second.calls, 0);
      first.progress!(
        const ImagePreparationProgress(stage: 'Decoding image', fraction: 0.4),
      );
      await tester.pump();
      expect(find.textContaining('Decoding image'), findsOneWidget);
      first.pending.complete(preparedPixel('first.png'));
      await tester.pumpAndSettle();
      expect(second.calls, 1);
      expect(preview(), findsOneWidget);
      second.pending.complete(preparedPixel('second.png', red: true));
      await tester.pumpAndSettle();
      expect(find.textContaining('2 prepared'), findsOneWidget);
      expect(preview(), findsOneWidget);
      expect(first.disposals, greaterThanOrEqualTo(1));
      expect(second.disposals, greaterThanOrEqualTo(1));
      expect(controller.cardCreates, 0);
      expect(controller.snapshot!.drafts, isEmpty);
    },
  );

  testWidgets(
    'Identical normalized content is reported as duplicate without retaining another preview',
    (tester) async {
      final first = ControlledSource(
        'first.png',
        output: preparedPixel('first.png'),
      );
      final duplicate = ControlledSource(
        'renamed.png',
        output: preparedPixel('renamed.png'),
      );
      await show(tester, [first, duplicate]);
      await start(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('1 prepared'), findsOneWidget);
      expect(find.textContaining('1 duplicates'), findsOneWidget);
      expect(find.text('Duplicate'), findsOneWidget);
      expect(preview(), findsOneWidget);
      expect(first.disposals, greaterThanOrEqualTo(1));
      expect(duplicate.disposals, greaterThanOrEqualTo(1));
    },
  );

  testWidgets('A failed image does not abort the remaining valid images', (
    tester,
  ) async {
    final bad = ControlledSource(
      'broken.png',
      error: const FormatException('Corrupt image'),
    );
    final good = ControlledSource(
      'valid.png',
      output: preparedPixel('valid.png'),
    );
    await show(tester, [bad, good]);
    await start(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('1 failed'), findsOneWidget);
    expect(find.textContaining('1 prepared'), findsOneWidget);
    expect(find.text('Failed'), findsOneWidget);
    expect(good.calls, 1);
    expect(bad.disposals, greaterThanOrEqualTo(1));
    expect(good.disposals, greaterThanOrEqualTo(1));
    expect(preview(), findsOneWidget);
  });

  testWidgets(
    'Cancellation rejects a late result and never starts the next image',
    (tester) async {
      final slow = ControlledSource('slow.png');
      final unstarted = ControlledSource('later.png');
      await show(tester, [slow, unstarted]);
      await start(tester);
      await tester.tap(find.text('Cancel preparation'));
      await tester.pump();
      expect(slow.cancellation!.isCancelled, isTrue);
      slow.pending.complete(preparedPixel('slow.png'));
      await tester.pumpAndSettle();
      expect(unstarted.calls, 0);
      expect(preview(), findsNothing);
      expect(find.textContaining('0 prepared'), findsOneWidget);
      expect(slow.disposals, greaterThanOrEqualTo(1));
      expect(unstarted.disposals, greaterThanOrEqualTo(1));
    },
  );

  testWidgets(
    'Scope loss cancels pending work, clears private results and closes the panel',
    (tester) async {
      final slow = ControlledSource('private.png');
      var closes = 0;
      await show(tester, [slow], onClose: () => closes++);
      await start(tester);
      controller.clearAccount();
      await tester.pump();
      expect(slow.cancellation!.isCancelled, isTrue);
      slow.pending.complete(preparedPixel('private.png'));
      await tester.pumpAndSettle();
      expect(closes, 1);
      expect(preview(), findsNothing);
      expect(find.text('private.png'), findsNothing);
      expect(slow.disposals, greaterThanOrEqualTo(1));
    },
  );

  testWidgets(
    'Sources returned by a picker after account loss are disposed without preparation',
    (tester) async {
      final picker = Completer<List<ImagePreparationSource>>();
      final late = ControlledSource('private-late.png');
      var closes = 0;
      await show(
        tester,
        [],
        pickSources: () => picker.future,
        onClose: () => closes++,
      );
      await start(tester);
      controller.clearAccount();
      await tester.pump();
      picker.complete([late]);
      await tester.pumpAndSettle();
      expect(closes, 1);
      expect(late.calls, 0);
      expect(late.disposals, greaterThanOrEqualTo(1));
      expect(find.text('private-late.png'), findsNothing);
      expect(preview(), findsNothing);
    },
  );

  testWidgets(
    'A cancelled file selection keeps the panel available without creating drafts',
    (tester) async {
      await show(tester, []);
      await start(tester);
      await tester.pumpAndSettle();
      expect(find.text('Select images'), findsOneWidget);
      expect(find.text('Cancel preparation'), findsNothing);
      expect(preview(), findsNothing);
      expect(controller.cardCreates, 0);
      expect(controller.snapshot!.drafts, isEmpty);
    },
  );

  testWidgets(
    'Closing preparation cancels the active source and releases selected files',
    (tester) async {
      final slow = ControlledSource('slow.png');
      var closes = 0;
      await show(tester, [slow], onClose: () => closes++);
      await start(tester);
      await tester.tap(find.text('Close image preparation'));
      await tester.pump();
      expect(closes, 1);
      expect(slow.cancellation!.isCancelled, isTrue);
      slow.pending.complete(preparedPixel('slow.png'));
      await tester.pumpAndSettle();
      expect(slow.disposals, greaterThanOrEqualTo(1));
      expect(preview(), findsNothing);
    },
  );

  testWidgets(
    'Preparation summary and controls fit a 360 pixel viewport at 200 percent text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final source = ControlledSource(
        '長い画像ファイル名 with spaces and repeated labels.png',
        output: preparedPixel('長い画像ファイル名 with spaces.png'),
      );
      await show(tester, [source], scale: 2);
      expect(tester.takeException(), isNull);
      await start(tester);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(preview(), findsOneWidget);
      expect(controller.cardCreates, 0);
    },
  );

  testWidgets(
    'Cancelling Card image preparation retains the previous image and typed name',
    (tester) async {
      final replacement = Completer<CardImage?>();
      final original = preparedPixel('original.png');
      final card = CardSummary(
        id: 'card-a',
        name: 'Existing identity',
        imageReference: null,
        difficulty: 2,
        packId: 'owned',
        state: 'active',
        revision: 2,
        pending: LocalDraft(
          id: 'draft-a',
          resourceType: 'card',
          resourceId: 'card-a',
          baseRevision: 2,
          value: {
            'name': 'Existing identity',
            'packId': 'owned',
            'difficulty': 2,
          },
          localImage: original,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => CardDraftDialog(
                    controller: controller,
                    packId: 'owned',
                    card: card,
                    pickImage: () => replacement.future,
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
      await tester.enterText(topicField('Card name'), 'Typed name stays');
      await tester.ensureVisible(find.text('Replace image'));
      await tester.tap(find.text('Replace image'));
      await tester.pump();
      await tester.ensureVisible(find.text('Cancel image preparation'));
      await tester.tap(find.text('Cancel image preparation'));
      await tester.pump();
      replacement.complete(preparedPixel('late.png', red: true));
      await tester.pumpAndSettle();
      expect(find.text('original.png'), findsOneWidget);
      expect(find.text('late.png'), findsNothing);
      expect(
        tester.widget<TextField>(topicField('Card name')).controller!.text,
        'Typed name stays',
      );
      expect(controller.cardEdits, 0);
      await tester.ensureVisible(find.text('Save Card locally'));
      await tester.tap(find.text('Save Card locally'));
      await tester.pumpAndSettle();
      expect(controller.savedImage!.filename, 'original.png');
      expect(controller.savedCardName, 'Typed name stays');
    },
  );
}
