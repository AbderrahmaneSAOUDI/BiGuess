import 'package:biguess/presentation/controllers/app_version_controller.dart';
import 'package:biguess/presentation/controllers/update_controller.dart';
import 'package:biguess/presentation/dialogs/info/tabs/about_game_tab.dart';
import 'package:biguess/providers/gameplay_network_gate.dart';
import 'package:biguess/services/ota_installer_service.dart';
import 'package:biguess/services/shorebird_patch_service.dart';
import 'package:biguess/services/version_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoPatch implements ShorebirdPatchService {
  @override
  Future<bool> isShorebirdAvailable() async => false;
  @override
  Future<bool> checkForPatch() async => false;
  @override
  Future<bool> downloadAndApplyPatch() async => false;
}

class _CountingUpdates extends UpdateController {
  _CountingUpdates()
    : super(
        versionService: const VersionService(),
        otaInstaller: OtaInstallerService(),
        shorebirdPatch: _NoPatch(),
      );
  int checks = 0;
  @override
  Future<void> checkForUpdates({bool silent = false}) async {
    checks++;
  }
}

void main() {
  Future<void> show(
    WidgetTester tester, {
    required bool blocked,
    required UpdateController Function() updates,
  }) async {
    tester.view.physicalSize = const Size(480, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gameplayNetworkBlockedProvider.overrideWithValue(blocked),
          appVersionProvider.overrideWith(
            (ref) async => '1.0.0',
          ),
          updateControllerProvider.overrideWith((ref) => updates()),
        ],
        child: const MaterialApp(home: Scaffold(body: AboutGameTab())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets(
    'session About keeps local information without constructing updater or exposing network actions',
    (tester) async {
      var updaterReads = 0;
      await show(
        tester,
        blocked: true,
        updates: () {
          updaterReads++;
          throw StateError('A game must not create an app updater');
        },
      );
      expect(find.text('Version 1.0.0'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('session-update-hint')),
        250,
      );
      expect(
        find.text('Return to Packs to check for app updates.'),
        findsOneWidget,
      );
      expect(find.text('Check'), findsNothing);
      expect(find.text('Update'), findsNothing);
      expect(find.text('Manage'), findsNothing);
      expect(updaterReads, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Home About retains explicit manual app-update check', (
    tester,
  ) async {
    final controller = _CountingUpdates();
    await show(tester, blocked: false, updates: () => controller);
    await tester.scrollUntilVisible(find.text('Check'), 250);
    await tester.ensureVisible(find.text('Check'));
    await tester.pump(const Duration(seconds: 1));
    expect(controller.checks, 0);
    await tester.tap(find.text('Check'));
    await tester.pump();
    expect(controller.checks, 1);
    expect(
      find.text('Return to Packs to check for app updates.'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
