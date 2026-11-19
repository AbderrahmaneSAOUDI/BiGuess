import 'dart:io';

import 'package:biguess/data/local/local_content_runtime.dart';
import 'package:biguess/domain/models/update_decision.dart';
import 'package:biguess/domain/models/update_state.dart';
import 'package:biguess/main.dart';
import 'package:biguess/presentation/controllers/update_controller.dart';
import 'package:biguess/presentation/dialogs/update/update_dialog.dart';
import 'package:biguess/presentation/screens/topics/topics_screen.dart';
import 'package:biguess/providers/catalog_controller.dart';
import 'package:biguess/providers/topic_pack_providers.dart';
import 'package:biguess/services/ota_installer_service.dart';
import 'package:biguess/services/shorebird_patch_service.dart';
import 'package:biguess/services/version_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoVersionIO implements VersionService {
  @override
  void cancelPendingRequests() {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unrequested version IO: $invocation');
}

class _NoApkIO implements OtaInstallerService {
  @override
  void cancelDownload() {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unrequested APK IO: $invocation');
}

class _NoPatchIO implements ShorebirdPatchService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unrequested native update IO: $invocation');
}

class _ObservedUpdates extends UpdateController {
  _ObservedUpdates()
    : super(
        versionService: _NoVersionIO(),
        otaInstaller: _NoApkIO(),
        shorebirdPatch: _NoPatchIO(),
      );
  int checks = 0;
  @override
  Future<void> checkForUpdates() async {
    checks++;
  }

  void offerLegacyHint() {
    state = const UpdateAvailable(
      decision: UpdateFullApk(
        mandatory: true,
        apkUrl: 'https://example.invalid/app.apk',
        releaseNotes: '',
        latestVersion: '99.0.0',
      ),
      currentVersion: '1.0.0',
      latestVersion: '99.0.0',
      releaseNotes: '',
    );
  }

  void offlineError() {
    state = const UpdateError(message: 'Server unavailable', canSkip: false);
  }
}

void main() {
  for (final mode in ['installed', 'empty fallback', 'explicit rollback']) {
    testWidgets(
      '$mode launches and rebuilds without checks or forced update UI',
      (tester) async {
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('manual-launch-'),
        ))!;
        final runtime = (await tester.runAsync(
          () => LocalContentRuntime.open(
            supportDirectory: directory,
            importFile: mode == 'installed'
                ? File('test/fixtures/local_pack/colors.biguesspack')
                : null,
            useLegacy: mode == 'explicit rollback',
          ),
        ))!;
        final updates = _ObservedUpdates();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              localContentRuntimeProvider.overrideWithValue(runtime),
              updateControllerProvider.overrideWith((ref) => updates),
            ],
            child: const BiGuessApp(),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 30));
        expect(find.byType(TopicsScreen), findsOneWidget);
        expect(updates.checks, 0);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(TopicsScreen)),
        );
        expect(container.read(automaticUpdateChecksProvider), isFalse);
        updates.offerLegacyHint();
        await tester.pump();
        expect(find.byType(UpdateDialog), findsNothing);
        updates.offlineError();
        container.invalidate(browseTopicsProvider);
        await tester.pump();
        await tester.pump(const Duration(seconds: 30));
        expect(updates.checks, 0);
        expect(find.byType(UpdateDialog), findsNothing);
        expect(find.text('Server unavailable'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await runtime.releasePlayback();
          runtime.close();
          await directory.delete(recursive: true);
        });
      },
    );
  }
}
