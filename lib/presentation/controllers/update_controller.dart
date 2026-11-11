import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:restart_app/restart_app.dart';

import '../../domain/models/remote_version.dart';
import '../../domain/models/sem_ver.dart';
import '../../domain/models/update_decision.dart';
import '../../domain/models/update_state.dart';
import '../../providers/gameplay_network_gate.dart';
import '../../services/ota_installer_service.dart';
import '../../services/shorebird_patch_service.dart';
import '../../services/version_service.dart';

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

final versionServiceProvider = Provider<VersionService>((_) {
  return const VersionService();
});

final otaInstallerServiceProvider = Provider<OtaInstallerService>((_) {
  return OtaInstallerService();
});

final shorebirdPatchServiceProvider = Provider<ShorebirdPatchService>((_) {
  return ShorebirdPatchService();
});

final updateControllerProvider =
    StateNotifierProvider<UpdateController, UpdateState>((ref) {
      final controller = UpdateController(
        versionService: ref.watch(versionServiceProvider),
        otaInstaller: ref.watch(otaInstallerServiceProvider),
        shorebirdPatch: ref.watch(shorebirdPatchServiceProvider),
      );
      ref.listen(gameplayNetworkBlockedProvider, (previous, blocked) {
        if (blocked) {
          unawaited(controller.pauseForGameplay());
        } else {
          controller.resumeAfterGameplay();
        }
      }, fireImmediately: true);
      return controller;
    });

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

/// Orchestrates the update pipeline across the app.
///
/// Supports silent background checking on launch and interactive manual checks
/// from the About/Settings tab.
class UpdateController extends StateNotifier<UpdateState> {
  final VersionService _versionService;
  final OtaInstallerService _otaInstaller;
  final ShorebirdPatchService _shorebirdPatch;

  SemVer? _localVersion;
  SemVer? _minRequired;
  RemoteVersion? _remoteVersion;
  final _pendingOperations = <Future<void>>{};
  bool _gameplayPaused = false;
  int _operationEpoch = 0;

  UpdateController({
    required VersionService versionService,
    required OtaInstallerService otaInstaller,
    required ShorebirdPatchService shorebirdPatch,
  }) : _versionService = versionService,
       _otaInstaller = otaInstaller,
       _shorebirdPatch = shorebirdPatch,
       super(const UpdateIdle());

  SemVer? get localVersion => _localVersion;
  SemVer? get minRequired => _minRequired;
  RemoteVersion? get remoteVersion => _remoteVersion;

  bool _canContinue(int epoch) =>
      mounted && !_gameplayPaused && epoch == _operationEpoch;

  Future<void> _track(Future<void> Function(int epoch) operation) {
    if (!mounted || _gameplayPaused) return Future.value();
    final epoch = _operationEpoch;
    final pending = Future<void>.sync(() => operation(epoch));
    _pendingOperations.add(pending);
    return pending.whenComplete(() => _pendingOperations.remove(pending));
  }

  /// Stop cancellable app-update IO and wait for any native operation already
  /// underway. No network operation may start until Home explicitly resumes it.
  Future<void> pauseForGameplay() async {
    _gameplayPaused = true;
    _operationEpoch++;
    _versionService.cancelPendingRequests();
    _otaInstaller.cancelDownload();
    if (mounted) state = const UpdateSkipped();
    await Future.wait([
      for (final pending in _pendingOperations.toList())
        pending.then<void>(
          (_) {},
          onError: (Object error, StackTrace trace) {},
        ),
    ]);
  }

  /// Restores manual/ordinary update eligibility without initiating a check.
  void resumeAfterGameplay() {
    if (!mounted) return;
    _gameplayPaused = false;
    state = const UpdateIdle();
  }

  @override
  void dispose() {
    _gameplayPaused = true;
    _operationEpoch++;
    _versionService.cancelPendingRequests();
    _otaInstaller.cancelDownload();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Check for updates
  // -------------------------------------------------------------------------

  /// Runs the update check.
  ///
  /// If [silent] is true, network failures or up-to-date states will complete
  /// silently without surfacing errors to avoid interrupting gameplay.
  Future<void> checkForUpdates({bool silent = false}) =>
      _track((epoch) => _checkForUpdates(silent: silent, epoch: epoch));

  Future<void> _checkForUpdates({
    required bool silent,
    required int epoch,
  }) async {
    if (!_canContinue(epoch)) return;
    if (!kReleaseMode) {
      state = UpdateCompleted(
        silent
            ? ''
            : 'Updates require the signed release app. Debug/profile builds use '
                  'development signing. Install the release APK '
                  'to test updates; removing a development installation erases its local data.',
      );
      return;
    }
    state = const UpdateChecking();
    if (!_canContinue(epoch)) return;

    try {
      // 1. Resolve local installed version
      _localVersion = await _versionService.getLocalVersion();
      if (!_canContinue(epoch)) return;
      final local = _localVersion!;

      // 2. First check if a Shorebird patch is ready
      final isSbAvailable = await _shorebirdPatch.isShorebirdAvailable();
      if (!_canContinue(epoch)) return;
      if (isSbAvailable) {
        final hasPatch = await _shorebirdPatch.checkForPatch();
        if (!_canContinue(epoch)) return;
        if (hasPatch) {
          if (silent) {
            // Apply patch silently in the background
            final applied = await _shorebirdPatch.downloadAndApplyPatch();
            if (!_canContinue(epoch)) return;
            if (applied) {
              state = const UpdateCompleted(
                'New patch installed. Restart anytime to apply.',
              );
            } else {
              state = const UpdateCompleted();
            }
            return;
          } else {
            if (!_canContinue(epoch)) return;
            state = UpdateAvailable(
              decision: const UpdateShorebirdPatch(),
              currentVersion: local.toString(),
              latestVersion: local.toString(),
              releaseNotes:
                  'Over-the-air code patch available with instant bug fixes and improvements.',
            );
            return;
          }
        }
      }

      // 3. Fetch remote version manifest from GitHub (8s timeout)
      late final RemoteVersion remote;
      try {
        remote = await _versionService.fetchRemoteVersion();
        if (!_canContinue(epoch)) return;
        _remoteVersion = remote;
      } on TimeoutException {
        if (!silent && _canContinue(epoch)) {
          state = const UpdateError(
            message: 'Connection timed out while checking for updates.',
          );
        } else if (_canContinue(epoch)) {
          state = const UpdateCompleted();
        }
        return;
      } on SocketException {
        if (!silent && _canContinue(epoch)) {
          state = const UpdateError(
            message: 'No internet connection to check for updates.',
          );
        } else if (_canContinue(epoch)) {
          state = const UpdateCompleted();
        }
        return;
      } catch (e) {
        if (!silent && _canContinue(epoch)) {
          state = UpdateError(message: 'Failed to check for updates: $e');
        } else if (_canContinue(epoch)) {
          state = const UpdateCompleted();
        }
        return;
      }

      _minRequired = SemVer.parse(remote.minRequiredVersion);

      // 4. Query device CPU architecture & evaluate update decision
      final deviceAbis = await _versionService.getDeviceSupportedAbis();
      if (!_canContinue(epoch)) return;
      final decision = _versionService.evaluateUpdate(
        local,
        remote,
        deviceAbis: deviceAbis,
        isShorebirdAvailable: isSbAvailable,
      );

      if (!_canContinue(epoch)) return;

      switch (decision) {
        case UpdateNone():
          state = UpdateCompleted(
            silent
                ? ''
                : 'You are running the latest version (v${local.toString()})',
          );

        case UpdateFullApk():
          if (remote.apkUrls.keys.length == 1 &&
              remote.apkUrls.containsKey('arm64-v8a') &&
              deviceAbis.isNotEmpty &&
              !deviceAbis.contains('arm64-v8a')) {
            if (!_canContinue(epoch)) return;
            state = silent
                ? const UpdateCompleted()
                : const UpdateError(
                    message:
                        'This release requires a 64-bit ARM Android device.',
                    canRetry: false,
                  );
            return;
          }
          state = UpdateAvailable(
            decision: decision,
            currentVersion: local.toString(),
            latestVersion: remote.latestVersion,
            releaseNotes: decision.releaseNotes.isNotEmpty
                ? decision.releaseNotes
                : 'New version v${remote.latestVersion} available.',
          );

        case UpdateShorebirdPatch():
          if (silent) {
            // Silently download and apply the patch
            final applied = await _shorebirdPatch.downloadAndApplyPatch();
            if (applied && _canContinue(epoch)) {
              state = const UpdateCompleted(
                'Patch downloaded. Restart anytime.',
              );
            } else if (_canContinue(epoch)) {
              state = const UpdateCompleted();
            }
          } else {
            state = UpdateAvailable(
              decision: decision,
              currentVersion: local.toString(),
              latestVersion: remote.latestVersion,
              releaseNotes: remote.releaseNotes.isNotEmpty
                  ? remote.releaseNotes
                  : 'Fast OTA patch available.',
            );
          }
      }
    } catch (e) {
      debugPrint('UpdateController.checkForUpdates error: $e');
      if (!_canContinue(epoch)) return;
      if (silent) {
        state = const UpdateCompleted();
      } else {
        state = const UpdateError(
          message: 'An unexpected error occurred during version check.',
        );
      }
    }
  }

  // -------------------------------------------------------------------------
  // Full APK download & installation
  // -------------------------------------------------------------------------

  Future<void> downloadAndInstallApk(UpdateFullApk decision) =>
      _track((epoch) => _downloadAndInstallApk(decision, epoch));

  Future<void> _downloadAndInstallApk(UpdateFullApk decision, int epoch) async {
    if (!_canContinue(epoch)) return;
    if (!kReleaseMode) {
      state = const UpdateError(
        message: 'Install the signed release app to use APK updates.',
        canRetry: false,
      );
      return;
    }

    // Clean stale APKs first
    await _otaInstaller.cleanStaleApks();
    if (!_canContinue(epoch)) return;

    state = const UpdateDownloading(progress: 0, speedText: '', etaText: '');
    if (!_canContinue(epoch)) return;

    try {
      final apkFile = await _otaInstaller.downloadApk(
        decision.apkUrl,
        onProgress: (progress) {
          if (!_canContinue(epoch)) return;
          state = UpdateDownloading(
            progress: progress.fraction,
            speedText: progress.speedText,
            etaText: progress.etaText,
            totalBytes: progress.total,
            receivedBytes: progress.received,
          );
        },
      );

      if (!_canContinue(epoch)) return;
      state = const UpdateInstalling();
      if (!_canContinue(epoch)) return;

      await _otaInstaller.installApk(apkFile);

      if (!_canContinue(epoch)) return;
      state = const UpdateCompleted(
        'Installer launched. Follow the on-screen prompt to finish.',
      );
    } catch (e) {
      debugPrint('APK download/install error: $e');
      if (!_canContinue(epoch)) return;
      state = UpdateError(
        message: 'Download or installation failed. Please try again.',
        canRetry: true,
        canSkip: !decision.mandatory,
      );
    }
  }

  /// Re-launches the installer for an already downloaded APK file without re-downloading.
  Future<void> launchDownloadedApk() => _track(_launchDownloadedApk);

  Future<void> _launchDownloadedApk(int epoch) async {
    if (!_canContinue(epoch)) return;
    try {
      final file = await _otaInstaller.getDownloadedApk();
      if (!_canContinue(epoch)) return;
      if (file != null && file.existsSync()) {
        state = const UpdateInstalling();
        if (!_canContinue(epoch)) return;
        await _otaInstaller.installApk(file);
        if (!_canContinue(epoch)) return;
        state = const UpdateCompleted(
          'Installer launched. Follow the on-screen prompt to finish.',
        );
      } else {
        if (!_canContinue(epoch)) return;
        state = const UpdateError(
          message:
              'Downloaded package not found. Please try downloading again.',
          canRetry: true,
        );
      }
    } catch (e) {
      debugPrint('Launch installer error: $e');
      if (!_canContinue(epoch)) return;
      state = UpdateError(
        message: 'Failed to launch installer: $e',
        canRetry: true,
      );
    }
  }

  // -------------------------------------------------------------------------
  // Shorebird patch execution
  // -------------------------------------------------------------------------

  Future<void> applyShorebirdPatch() => _track(_applyShorebirdPatch);

  Future<void> _applyShorebirdPatch(int epoch) async {
    if (!_canContinue(epoch)) return;
    state = const UpdatePatching();
    if (!_canContinue(epoch)) return;

    try {
      final applied = await _shorebirdPatch.downloadAndApplyPatch();
      if (!applied) {
        if (!_canContinue(epoch)) return;
        state = const UpdateError(
          message: 'Failed to download patch. Please try again.',
        );
        return;
      }

      if (!_canContinue(epoch)) return;
      state = const UpdateRestarting();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!_canContinue(epoch)) return;
      try {
        await Restart.restartApp();
      } catch (e) {
        debugPrint('Restart error: $e');
        if (_canContinue(epoch)) {
          state = const UpdateCompleted('Patch ready. Please restart the app.');
        }
      }
    } catch (e) {
      debugPrint('Shorebird patch apply error: $e');
      if (!_canContinue(epoch)) return;
      state = const UpdateError(message: 'Failed to apply patch.');
    }
  }

  // -------------------------------------------------------------------------
  // User actions
  // -------------------------------------------------------------------------

  void skipUpdate() {
    if (!mounted) return;
    _otaInstaller.cancelDownload();
    state = const UpdateSkipped();
  }

  void resetToIdle() {
    if (!mounted) return;
    state = const UpdateIdle();
  }
}
