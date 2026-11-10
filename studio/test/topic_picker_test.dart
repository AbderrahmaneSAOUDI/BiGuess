import 'package:biguess_studio/app/studio_theme.dart';
import 'package:biguess_studio/data/topic_taxonomy.dart';
import 'package:biguess_studio/presentation/pack_draft_dialog.dart';
import 'package:biguess_studio/presentation/topic_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'topics_page_test.dart' show TopicUiController, topicField;

void main() {
  late TopicUiController controller;
  setUp(() {
    controller = TopicUiController(role: 'collector');
    controller.entries = [
      const TopicTaxonomy(
        id: 'active',
        name: 'Active taxonomy',
        state: 'active',
        revision: 1,
      ),
      const TopicTaxonomy(
        id: 'hidden',
        name: 'Hidden taxonomy',
        state: 'hidden',
        revision: 2,
      ),
      const TopicTaxonomy(
        id: 'deleted',
        name: 'Deleted taxonomy',
        state: 'deleted',
        revision: 3,
      ),
      const TopicTaxonomy(
        id: 'new',
        name: 'New unsynchronized taxonomy',
        state: 'active',
        revision: 0,
      ),
    ];
  });
  tearDown(() => controller.dispose());

  testWidgets(
    'picker permits existing hidden taxonomy and clears an invalidated selection',
    (tester) async {
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: StudioTheme.light,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => TopicPicker(
                controller: controller,
                value: selected,
                onChanged: (value) => setState(() => selected = value),
              ),
            ),
          ),
        ),
      );
      await tester.enterText(topicField('Find a Topic'), 'HIDDEN');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      expect(find.text('Deleted taxonomy'), findsNothing);
      expect(find.text('New unsynchronized taxonomy'), findsNothing);
      await tester.tap(find.text('Hidden taxonomy (hidden)').last);
      await tester.pumpAndSettle();
      expect(selected, 'hidden');
      controller.entries = [
        const TopicTaxonomy(
          id: 'hidden',
          name: 'Hidden taxonomy',
          state: 'deleted',
          revision: 3,
        ),
      ];
      controller.notifyListeners();
      await tester.pumpAndSettle();
      expect(selected, isNull);
    },
  );

  testWidgets(
    'Collector prepares a Pack independently with a durable parent choice; scope loss clears form',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: StudioTheme.light,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => PackDraftDialog(controller: controller),
                ),
                child: const Text('Prepare Pack'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Prepare Pack'));
      await tester.pumpAndSettle();
      await tester.enterText(topicField('Pack name'), 'My classified Pack');
      await tester.enterText(topicField('Find a Topic'), 'Hidden');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hidden taxonomy (hidden)').last);
      await tester.pumpAndSettle();
      expect(controller.packName, isNull);
      await tester.tap(find.text('Save Pack draft locally'));
      await tester.pumpAndSettle();
      expect(controller.packName, 'My classified Pack');
      expect(controller.packTopic, 'hidden');
      await tester.tap(find.text('Prepare Pack'));
      await tester.pumpAndSettle();
      await tester.enterText(
        topicField('Pack name'),
        'Other account private input',
      );
      controller.clearAccount();
      await tester.pumpAndSettle();
      expect(find.text('Other account private input'), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
  testWidgets(
    'picker clears account-specific selection even when shared taxonomy IDs remain',
    (tester) async {
      String? selected = 'active';
      await tester.pumpWidget(
        MaterialApp(
          theme: StudioTheme.light,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => TopicPicker(
                controller: controller,
                value: selected,
                onChanged: (value) => setState(() => selected = value),
              ),
            ),
          ),
        ),
      );
      expect(selected, 'active');
      controller.clearAccount();
      await tester.pumpAndSettle();
      expect(selected, isNull);
    },
  );

  testWidgets(
    'classification picker fits long labels on a narrow large-text screen',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      controller.entries = [
        const TopicTaxonomy(
          id: 'long',
          name: 'A very long hidden classification Topic with Unicode Éléphant labels',
          state: 'hidden',
          revision: 1,
        ),
      ];
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
              child: TopicPicker(
                controller: controller,
                value: 'long',
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
