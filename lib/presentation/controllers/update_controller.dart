import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart' as hashes;
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
/// App updates are explicit and optional. Pack synchronization uses a separate
/// controller/transport and cannot require a binary upgrade to start a game.
class UpdateController extends StateNotifier<UpdateState> {
  final VersionService _versionService;
  final OtaInstallerService _otaInstaller;
  final ShorebirdPatchService _shorebirdPatch;

  SemVer? _localVersion;
  SemVer? _minRequired;
  RemoteVersion? _remoteVersion;
  UpdateFullApk? _downloadedApkDecision;
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

  /// Explicitly check availability. This never downloads or applies a patch.
  Future<void> checkForUpdates() => _track(_checkForUpdates);

  Future<void> _checkForUpdates(int epoch) async {
    if (!_canContinue(epoch)) return;
    if (!kReleaseMode) {
      state = const UpdateCompleted(
        'Updates require the signed release app. Debug/profile builds use '
        'development signing. Install the release APK '
        'to test updates; removing a development installation erases its local data.',
      );
      return;
    }
    state = const UpdateChecking();
    if (!_canContinue(epoch)) return;
    try {
      _localVersion = await _versionService.getLocalVersion();
      if (!_canContinue(epoch)) return;
      final local = _localVersion!;
      final isSbAvailable = await _shorebirdPatch.isShorebirdAvailable();
      if (!_canContinue(epoch)) return;
      if (isSbAvailable) {
        final hasPatch = await _shorebirdPatch.checkForPatch();
        if (!_canContinue(epoch)) return;
        if (hasPatch) {
          state = UpdateAvailable(
            decision: const UpdateShorebirdPatch(),
            currentVersion: local.toString(),
            latestVersion: local.toString(),
            releaseNotes: 'An optional app patch is available.',
          );
          return;
        }
      }

      // 3. Fetch remote version manifest from GitHub (8s timeout)
      late final RemoteVersion remote;
      try {
        remote = await _versionService.fetchRemoteVersion();
        if (!_canContinue(epoch)) return;
        _remoteVersion = remote;
      } on TimeoutException {
        if (_canContinue(epoch)) {
          state = const UpdateError(
            message: 'Connection timed out while checking for updates.',
          );
        }
        return;
      } on SocketException {
        if (_canContinue(epoch)) {
          state = const UpdateError(
            message: 'No internet connection to check for updates.',
          );
        }
        return;
      } catch (e) {
        if (_canContinue(epoch)) {
          state = UpdateError(message: 'Failed to check for updates: $e');
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
            'You are running the latest version (v${local.toString()})',
          );

        case UpdateFullApk():
          if (remote.apkUrls.keys.length == 1 &&
              remote.apkUrls.containsKey('arm64-v8a') &&
              deviceAbis.isNotEmpty &&
              !deviceAbis.contains('arm64-v8a')) {
            if (!_canContinue(epoch)) return;
            state = const UpdateError(
              message: 'This release requires a 64-bit ARM Android device.',
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
          state = UpdateAvailable(
            decision: decision,
            currentVersion: local.toString(),
            latestVersion: remote.latestVersion,
            releaseNotes: remote.releaseNotes,
          );
      }
    } catch (e) {
      debugPrint('UpdateController.checkForUpdates error: $e');
      if (!_canContinue(epoch)) return;
      state = UpdateError(
        message:
            'Could not check app updates. Installed Packs remain available offline: $e',
      );
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

    final uri = Uri.tryParse(decision.apkUrl);
    final expectedHash = decision.sha256;
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        expectedHash == null ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(expectedHash)) {
      state = const UpdateError(
        message:
            'The app update has no valid secure download and checksum. Check again later.',
        canRetry: false,
      );
      return;
    }

    _downloadedApkDecision = null;
    try {
      await _otaInstaller.cleanStaleApks();
      if (!_canContinue(epoch)) return;
      state = const UpdateDownloading(progress: 0, speedText: '', etaText: '');
      if (!_canContinue(epoch)) return;
      final apkFile = await _otaInstaller.downloadApk(
        decision.apkUrl,
        expectedSha256: expectedHash,
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
      _downloadedApkDecision = decision;
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
      state = const UpdateError(
        message: 'Download or installation failed. Please try again.',
        canRetry: true,
        canSkip: true,
      );
    }
  }

  /// Re-launches the installer for an already downloaded APK file without re-downloading.
  Future<void> launchDownloadedApk() => _track(_launchDownloadedApk);

  Future<void> _launchDownloadedApk(int epoch) async {
    if (!_canContinue(epoch)) return;
    final decision = _downloadedApkDecision;
    if (decision?.sha256 == null) {
      state = const UpdateError(
        message: 'Check for app updates and download again before installing.',
        canRetry: false,
      );
      return;
    }
    try {
      final file = await _otaInstaller.getDownloadedApk();
      if (!_canContinue(epoch)) return;
      if (file == null || !await file.exists()) {
        state = const UpdateError(
          message: 'Downloaded app update is missing. Download it again.',
          canRetry: false,
        );
        return;
      }
      final digest = await hashes.sha256.bind(file.openRead()).first;
      if (!_canContinue(epoch)) return;
      if (digest.toString() != decision!.sha256!.toLowerCase()) {
        _downloadedApkDecision = null;
        await _otaInstaller.cleanStaleApks();
        if (!_canContinue(epoch)) return;
        state = const UpdateError(
          message:
              'The cached app update failed verification. Download it again.',
          canRetry: false,
        );
        return;
      }
      state = const UpdateInstalling();
      if (!_canContinue(epoch)) return;
      await _otaInstaller.installApk(file);
      if (!_canContinue(epoch)) return;
      state = const UpdateCompleted(
        'Installer launched. Follow the on-screen prompt to finish.',
      );
    } catch (error) {
      if (!_canContinue(epoch)) return;
      state = const UpdateError(
        message:
            'The app update could not be verified or installed. Download it again.',
        canRetry: false,
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
