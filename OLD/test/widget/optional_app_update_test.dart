import 'package:biguess/presentation/controllers/app_version_controller.dart';
import 'package:biguess/presentation/controllers/update_controller.dart';
import 'package:biguess/presentation/dialogs/info/tabs/about_game_tab.dart';
import 'package:biguess/presentation/dialogs/update/update_dialog.dart';
import 'package:biguess/domain/models/update_decision.dart';
import 'package:biguess/domain/models/update_state.dart';
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

class _Ota implements OtaInstallerService {
  @override
  void cancelDownload() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _available = UpdateAvailable(
  decision: UpdateFullApk(
    mandatory: true,
    apkUrl: 'https://example.test/app.apk',
    releaseNotes: '',
  ),
  currentVersion: '1.534.141',
  latestVersion: '1.534.142',
  releaseNotes: '',
);

class _Updates extends UpdateController {
  _Updates(UpdateState initial)
    : super(
        versionService: const VersionService(),
        otaInstaller: _Ota(),
        shorebirdPatch: _NoPatch(),
      ) {
    state = initial;
  }
  int checks = 0, downloads = 0, patches = 0, skips = 0;
  @override
  Future<void> checkForUpdates() async {
    checks++;
    state = _available;
  }

  @override
  Future<void> downloadAndInstallApk(UpdateFullApk decision) async {
    downloads++;
  }

  @override
  Future<void> applyShorebirdPatch() async {
    patches++;
  }

  @override
  void skipUpdate() {
    skips++;
    state = const UpdateSkipped();
  }
}

void main() {
  Future<void> show(
    WidgetTester tester,
    _Updates controller, {
    bool about = false,
  }) async {
    tester.view.physicalSize = const Size(480, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          updateControllerProvider.overrideWith((ref) => controller),
          appVersionProvider.overrideWith((ref) async => '1.0.0'),
        ],
        child: MaterialApp(
          home: about
              ? const Scaffold(body: AboutGameTab())
              : Scaffold(
                  body: Builder(
                    builder: (context) => TextButton(
                      onPressed: () => UpdateDialog.show(context),
                      child: const Text('Open app updates'),
                    ),
                  ),
                ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('Open app updates'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets(
    'remote mandatory hint cannot block barrier, Back or close dismissal',
    (tester) async {
      final controller = _Updates(_available);
      await show(tester, controller);
      await open(tester);
      expect(find.text('App Updates'), findsOneWidget);
      expect(find.text('Required Update'), findsNothing);
      expect(find.textContaining('required to continue'), findsNothing);
      expect(controller.downloads, 0);
      expect(controller.checks, 0);
      await tester.tapAt(const Offset(4, 4));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(UpdateDialog), findsNothing);
      await open(tester);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(UpdateDialog), findsNothing);
      await open(tester);
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(UpdateDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'About check and app installation are distinct explicit actions from Pack updates',
    (tester) async {
      final controller = _Updates(const UpdateIdle());
      await show(tester, controller, about: true);
      await tester.scrollUntilVisible(find.text('Check'), 250);
      await tester.ensureVisible(find.text('Check'));
      expect(find.text('App updates'), findsOneWidget);
      expect(
        find.text('Downloaded Pack updates are managed separately from Home.'),
        findsOneWidget,
      );
      expect(controller.checks, 0);
      await tester.tap(find.text('Check'));
      await tester.pump();
      expect(controller.checks, 1);
      expect(controller.downloads, 0);
      await tester.tap(find.text('Update'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(UpdateDialog), findsOneWidget);
      expect(controller.downloads, 0);
      await tester.tap(find.text('Download & Install APK'));
      await tester.pump();
      expect(controller.downloads, 1);
      expect(controller.patches, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'non-skippable remote error remains closable and disabled retry is honored',
    (tester) async {
      final controller = _Updates(
        const UpdateError(
          message: 'Server unavailable',
          canRetry: false,
          canSkip: false,
        ),
      );
      await show(tester, controller);
      await open(tester);
      expect(find.text('Server unavailable'), findsOneWidget);
      final retry = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Retry'),
      );
      expect(retry.onPressed, isNull);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Close'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(UpdateDialog), findsNothing);
      expect(controller.checks, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('explicit APK transfer always exposes cancellation', (
    tester,
  ) async {
    final controller = _Updates(
      const UpdateDownloading(progress: .4, speedText: '', etaText: ''),
    );
    await show(tester, controller);
    await open(tester);
    await tester.tap(find.text('Cancel Download'));
    await tester.pump();
    expect(controller.skips, 1);
    expect(find.text('Update was cancelled.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
