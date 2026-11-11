import 'dart:async';
import 'dart:io';

import 'package:biguess/domain/models/remote_version.dart';
import 'package:biguess/domain/models/sem_ver.dart';
import 'package:biguess/domain/models/update_decision.dart';
import 'package:biguess/domain/models/update_state.dart';
import 'package:biguess/presentation/controllers/update_controller.dart';
import 'package:biguess/services/ota_installer_service.dart';
import 'package:biguess/services/shorebird_patch_service.dart';
import 'package:biguess/services/version_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Version extends VersionService {
  int locals = 0, remotes = 0, cancellations = 0;
  @override
  Future<SemVer> getLocalVersion() async {
    locals++;
    return SemVer.zero;
  }

  @override
  Future<RemoteVersion> fetchRemoteVersion() async {
    remotes++;
    throw StateError('Unexpected version request');
  }

  @override
  void cancelPendingRequests() => cancellations++;
}

class _Patch implements ShorebirdPatchService {
  int checks = 0, downloads = 0;
  Completer<bool> pending = Completer<bool>();
  @override
  Future<bool> isShorebirdAvailable() async => true;
  @override
  Future<bool> checkForPatch() async {
    checks++;
    return false;
  }

  @override
  Future<bool> downloadAndApplyPatch() {
    downloads++;
    return pending.future;
  }
}

class _Ota implements OtaInstallerService {
  int downloads = 0, installs = 0, cancellations = 0;
  Completer<File?>? pendingFile;
  @override
  Future<void> cleanStaleApks() async {}
  @override
  Future<File?> getDownloadedApk() => pendingFile?.future ?? Future.value(null);
  @override
  Future<File> downloadApk(
    String url, {
    void Function(DownloadProgress)? onProgress,
  }) async {
    downloads++;
    throw StateError('Unexpected APK request');
  }

  @override
  Future<void> installApk(File file) async => installs++;
  @override
  void cancelDownload() => cancellations++;
}

class _RedirectClient implements HttpClient {
  _RedirectClient(this.delegate, this.uri);
  final HttpClient delegate;
  final Uri uri;
  bool forced = false;
  @override
  set connectionTimeout(Duration? value) => delegate.connectionTimeout = value;
  @override
  Future<HttpClientRequest> getUrl(Uri url) => delegate.getUrl(uri);
  @override
  void close({bool force = false}) {
    forced |= force;
    delegate.close(force: force);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HttpClients extends HttpOverrides {
  _HttpClients(this.clients);
  final List<_RedirectClient> clients;
  int calls = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) => clients[calls++];
}

void main() {
  late _Version version;
  late _Patch patch;
  late _Ota ota;
  late UpdateController controller;
  setUp(() {
    version = _Version();
    patch = _Patch();
    ota = _Ota();
    controller = UpdateController(
      versionService: version,
      otaInstaller: ota,
      shorebirdPatch: patch,
    );
  });
  tearDown(() => controller.dispose());

  test(
    'gameplay pause waits existing native patch and suppresses later restart/new work',
    () async {
      final operation = controller.applyShorebirdPatch();
      expect(patch.downloads, 1);
      var quiet = false;
      final pause = controller.pauseForGameplay().then((_) => quiet = true);
      await Future<void>.delayed(Duration.zero);
      expect(quiet, isFalse);
      expect(version.cancellations, 1);
      expect(ota.cancellations, 1);
      await controller.checkForUpdates();
      await controller.applyShorebirdPatch();
      expect(patch.downloads, 1);
      patch.pending.complete(true);
      await Future.wait([operation, pause]);
      expect(quiet, isTrue);
      expect(controller.state, isA<UpdateSkipped>());
      controller.resumeAfterGameplay();
      expect(controller.state, isA<UpdateIdle>());
      expect(patch.downloads, 1);
      patch.pending = Completer<bool>()..complete(false);
      await controller.applyShorebirdPatch();
      expect(patch.downloads, 2);
    },
  );

  test('pause during installer lookup never launches the next stage', () async {
    final directory = await Directory.systemTemp.createTemp('update-gameplay-');
    addTearDown(() => directory.delete(recursive: true));
    final file = await File(
      '${directory.path}/fixture.apk',
    ).writeAsString('fixture');
    ota.pendingFile = Completer<File?>();
    final lookup = controller.launchDownloadedApk();
    final pause = controller.pauseForGameplay();
    ota.pendingFile!.complete(file);
    await Future.wait([lookup, pause]);
    expect(ota.installs, 0);
    expect(controller.state, isA<UpdateSkipped>());
    await controller.launchDownloadedApk();
    expect(ota.installs, 0);
  });

  test(
    'development signing guard still prevents version/APK network work',
    () async {
      await controller.checkForUpdates();
      await controller.downloadAndInstallApk(
        const UpdateFullApk(
          mandatory: false,
          apkUrl: 'https://invalid.example/app.apk',
          releaseNotes: '',
        ),
      );
      expect(version.locals, 0);
      expect(version.remotes, 0);
      expect(patch.checks, 0);
      expect(ota.downloads, 0);
      expect(controller.state, isA<UpdateError>());
      expect((controller.state as UpdateError).canRetry, isFalse);
    },
  );

  test(
    'VersionService cancellation closes only its own active HTTP body',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final responses = Completer<void>();
      var requests = 0;
      server.listen((request) async {
        request.response.write('{');
        await request.response.flush();
        if (++requests == 2) responses.complete();
      });
      final uri = Uri.parse('http://127.0.0.1:${server.port}/version');
      final firstClient = _RedirectClient(HttpClient(), uri);
      final secondClient = _RedirectClient(HttpClient(), uri);
      final overrides = _HttpClients([firstClient, secondClient]);
      // Distinct identities are required to prove per-instance cancellation.
      // ignore: prefer_const_constructors
      final firstService = VersionService();
      // ignore: prefer_const_constructors
      final secondService = VersionService();
      try {
        await HttpOverrides.runWithHttpOverrides(() async {
          final first = firstService.fetchRemoteVersion();
          var secondFinished = false;
          final second = secondService.fetchRemoteVersion().whenComplete(
            () => secondFinished = true,
          );
          // Attach error listeners before cancellation closes the bodies.
          final firstFailure = expectLater(first, throwsA(isA<Exception>()));
          final secondFailure = expectLater(second, throwsA(isA<Exception>()));
          await responses.future.timeout(const Duration(seconds: 3));
          firstService.cancelPendingRequests();
          await firstFailure.timeout(const Duration(seconds: 3));
          expect(firstClient.forced, isTrue);
          expect(secondClient.forced, isFalse);
          expect(secondFinished, isFalse);
          secondService.cancelPendingRequests();
          await secondFailure.timeout(const Duration(seconds: 3));
          expect(secondClient.forced, isTrue);
        }, overrides);
      } finally {
        firstClient.close(force: true);
        secondClient.close(force: true);
        await server.close(force: true);
      }
    },
  );
}
