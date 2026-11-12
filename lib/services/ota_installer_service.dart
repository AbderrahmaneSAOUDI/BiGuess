import 'dart:io';

import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';

/// Progress data emitted during an APK download.
class DownloadProgress {
  /// Bytes received so far.
  final int received;

  /// Total expected bytes (0 when the server omits Content-Length).
  final int total;

  /// Fraction downloaded (0.0–1.0). Indeterminate when [total] == 0.
  final double fraction;

  /// Human-readable speed string, e.g. `"2.4 MB/s"`.
  final String speedText;

  /// Human-readable ETA string, e.g. `"~12s left"`.
  final String etaText;

  const DownloadProgress({
    required this.received,
    required this.total,
    required this.fraction,
    required this.speedText,
    required this.etaText,
  });
}

/// Manages full APK downloads, file integrity, cache cleanup, and
/// triggering the native Android package installer.
class OtaInstallerService {
  /// Name used for the in-flight download temp file.
  static const String _tempFileName = 'update.apk.tmp';

  /// Name of the completed APK file.
  static const String _apkFileName = 'update.apk';

  final Dio _dio;
  final Future<Directory> Function() _temporaryDirectory;
  final Future<List<Directory>?> Function() _externalCacheDirectories;
  CancelToken? _cancelToken;

  OtaInstallerService({
    Dio? dio,
    Future<Directory> Function()? temporaryDirectory,
    Future<List<Directory>?> Function()? externalCacheDirectories,
  }) : _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _externalCacheDirectories =
           externalCacheDirectories ?? getExternalCacheDirectories,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 15),
               receiveTimeout: const Duration(minutes: 5),
             ),
           );

  // ---------------------------------------------------------------------------
  // Cache cleanup & Inspection
  // ---------------------------------------------------------------------------

  /// Purges any stale `.apk` or `.apk.tmp` files from the app cache directory.
  Future<void> cleanStaleApks() async {
    final dirs = <Directory>[];
    try {
      final cacheDir = await _externalCacheDirectories();
      if (cacheDir != null) dirs.addAll(cacheDir);
    } catch (_) {}

    try {
      dirs.add(await _temporaryDirectory());
    } catch (_) {}

    for (final dir in dirs) {
      try {
        if (!dir.existsSync()) continue;
        final files = dir.listSync();
        for (final entity in files) {
          if (entity is File &&
              (entity.path.endsWith('.apk') ||
                  entity.path.endsWith('.apk.tmp'))) {
            try {
              await entity.delete();
            } catch (_) {
              // Best-effort cleanup — ignore individual file errors.
            }
          }
        }
      } catch (_) {
        // Ignore individual directory permission errors
      }
    }
  }

  /// Returns the completed APK file from disk if it exists.
  Future<File?> getDownloadedApk() async {
    try {
      final cacheDir = await _temporaryDirectory();
      final file = File('${cacheDir.path}/$_apkFileName');
      if (file.existsSync()) return file;
    } catch (_) {}
    return null;
  }

  // ---------------------------------------------------------------------------
  // Download
  // ---------------------------------------------------------------------------

  /// Downloads the APK from [url], streaming progress via [onProgress].
  ///
  /// Writes to a `.tmp` file first and renames to `.apk` only after the
  /// download completes successfully and any supplied SHA-256 matches.
  /// The controller requires a publisher checksum for production APK updates.
  ///
  /// Returns the completed [File] handle to the APK on disk.
  Future<File> downloadApk(
    String url, {
    void Function(DownloadProgress)? onProgress,
    String? expectedSha256,
  }) async {
    if (_cancelToken != null) {
      throw StateError('An APK download is already active');
    }
    if (expectedSha256 != null &&
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(expectedSha256)) {
      throw const FormatException('Invalid APK SHA-256');
    }
    final token = CancelToken();
    _cancelToken = token;
    File? tmpFile;
    File? finalFile;
    var completed = false;
    var ownsPaths = false;
    void checkCancelled() {
      if (token.isCancelled) throw token.cancelError!;
    }

    try {
      final cacheDir = await _temporaryDirectory();
      final tmpPath = '${cacheDir.path}/$_tempFileName';
      final finalPath = '${cacheDir.path}/$_apkFileName';

      // Remove leftover files from previous attempts
      tmpFile = File(tmpPath);
      finalFile = File(finalPath);
      checkCancelled();
      ownsPaths = true;
      if (tmpFile.existsSync()) await tmpFile.delete();
      if (finalFile.existsSync()) await finalFile.delete();

      // Rolling speed tracker (keeps last 5 samples at ~500ms intervals)
      final speedSamples = <double>[];
      var lastSampleTime = DateTime.now();
      var lastSampleBytes = 0;

      checkCancelled();
      await _dio.download(
        url,
        tmpPath,
        cancelToken: token,
        onReceiveProgress: (received, total) {
          final now = DateTime.now();
          final elapsed = now.difference(lastSampleTime).inMilliseconds;

          // Sample speed every ~500ms
          if (elapsed >= 500) {
            final bytesInInterval = received - lastSampleBytes;
            final bytesPerSecond = bytesInInterval / (elapsed / 1000);
            speedSamples.add(bytesPerSecond);
            if (speedSamples.length > 5) speedSamples.removeAt(0);
            lastSampleTime = now;
            lastSampleBytes = received;
          }

          // Calculate rolling average speed
          final avgSpeed = speedSamples.isEmpty
              ? 0.0
              : speedSamples.reduce((a, b) => a + b) / speedSamples.length;

          // Calculate ETA
          final remaining = total > 0 ? total - received : 0;
          final etaSeconds = avgSpeed > 0 ? (remaining / avgSpeed).ceil() : 0;

          final fraction = total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;

          onProgress?.call(
            DownloadProgress(
              received: received,
              total: total,
              fraction: fraction,
              speedText: _formatSpeed(avgSpeed),
              etaText: etaSeconds > 0 ? '~${etaSeconds}s left' : '',
            ),
          );
        },
      );

      checkCancelled();
      if (expectedSha256 != null) {
        final digest = await hashes.sha256.bind(tmpFile.openRead()).first;
        checkCancelled();
        if (digest.toString() != expectedSha256.toLowerCase()) {
          throw const FormatException('APK SHA-256 verification failed');
        }
      }
      // Only verified, complete bytes become the installable cache file.
      File result;
      try {
        result = await File(tmpPath).rename(finalPath);
      } catch (_) {
        result = await File(tmpPath).copy(finalPath);
        try {
          await File(tmpPath).delete();
        } catch (_) {}
      }
      checkCancelled();
      completed = true;
      return result;
    } finally {
      // Failed and cancelled transfers must not retain a partial APK.
      try {
        if (ownsPaths && tmpFile != null && await tmpFile.exists()) {
          await tmpFile.delete();
        }
        if (ownsPaths &&
            !completed &&
            finalFile != null &&
            await finalFile.exists()) {
          await finalFile.delete();
        }
      } on FileSystemException {
        // The next explicit download retries cleanup if storage is busy.
      } finally {
        if (identical(_cancelToken, token)) _cancelToken = null;
      }
    }
  }

  /// Cancels an in-flight download if one is active.
  void cancelDownload() {
    _cancelToken?.cancel('Download cancelled by user');
  }

  // ---------------------------------------------------------------------------
  // Install
  // ---------------------------------------------------------------------------

  /// Triggers the native Android package installer for the given APK [file].
  ///
  /// Uses the `open_filex` package which handles `FileProvider` content:// URIs
  /// and the `ACTION_INSTALL_PACKAGE` intent automatically.
  Future<void> installApk(File file) async {
    final result = await OpenFilex.open(
      file.path,
      type: 'application/vnd.android.package-archive',
    );

    if (result.type != ResultType.done) {
      throw Exception('Failed to launch installer: ${result.message}');
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond <= 0) return '0 B/s';
    if (bytesPerSecond >= 1024 * 1024) {
      return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
    if (bytesPerSecond >= 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(0)} KB/s';
    }
    return '${bytesPerSecond.toStringAsFixed(0)} B/s';
  }
}
