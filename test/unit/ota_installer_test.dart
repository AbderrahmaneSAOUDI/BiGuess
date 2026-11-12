import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashes;

import 'package:biguess/domain/models/update_decision.dart';
import 'package:biguess/domain/models/update_state.dart';
import 'package:biguess/presentation/controllers/update_controller.dart';
import 'package:biguess/services/ota_installer_service.dart';
import 'package:biguess/services/shorebird_patch_service.dart';
import 'package:biguess/services/version_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';

void main() {
  test('development updates stop before making network requests', () async {
    final controller = UpdateController(
      versionService: const VersionService(),
      otaInstaller: OtaInstallerService(),
      shorebirdPatch: ShorebirdPatchService(),
    );
    addTearDown(controller.dispose);
    await controller.checkForUpdates();
    expect(controller.state, isA<UpdateCompleted>());
    expect((controller.state as UpdateCompleted).message, contains('signing'));
    await controller.downloadAndInstallApk(
      const UpdateFullApk(
        mandatory: false,
        apkUrl: 'https://invalid.example/app.apk',
        releaseNotes: '',
        latestVersion: '2.0.0',
      ),
    );
    expect(controller.state, isA<UpdateError>());
    expect((controller.state as UpdateError).canRetry, isFalse);
  });

  group('APK storage', () {
    late Directory cache;
    late Directory external;
    late OtaInstallerService service;

    setUp(() async {
      cache = await Directory.systemTemp.createTemp('biguess-update-test');
      external = await cache.createTemp('external');
      service = OtaInstallerService(
        temporaryDirectory: () async => cache,
        externalCacheDirectories: () async => [external],
      );
    });
    tearDown(() async => cache.delete(recursive: true));

    test(
      'startup cleanup removes APKs and preserves other cached files',
      () async {
        for (final directory in [cache, external]) {
          await File('${directory.path}/update.apk').writeAsString('old APK');
          await File(
            '${directory.path}/update.apk.tmp',
          ).writeAsString('partial');
          await File('${directory.path}/image.webp').writeAsString('keep');
        }
        await service.cleanStaleApks();
        expect(await service.getDownloadedApk(), isNull);
        for (final directory in [cache, external]) {
          expect(
            File('${directory.path}/update.apk.tmp').existsSync(),
            isFalse,
          );
          expect(File('${directory.path}/image.webp').existsSync(), isTrue);
        }
      },
    );

    test(
      'completed APK remains available until the next startup cleanup',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) {
          request.response.add([1, 2, 3]);
          request.response.close();
        });
        final file = await service.downloadApk(
          'http://127.0.0.1:${server.port}/app.apk',
        );
        expect(await file.readAsBytes(), [1, 2, 3]);
        expect((await service.getDownloadedApk())?.path, file.path);
        expect(File('${cache.path}/update.apk.tmp').existsSync(), isFalse);
      },
    );

    test('cancelled transfer removes partial APK', () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            await File('${cache.path}/update.apk.tmp').writeAsString('partial');
            handler.reject(
              DioException.requestCancelled(
                requestOptions: options,
                reason: 'Cancelled transfer',
              ),
            );
          },
        ),
      );
      service = OtaInstallerService(
        dio: dio,
        temporaryDirectory: () async => cache,
        externalCacheDirectories: () async => [external],
      );
      await expectLater(
        service.downloadApk('https://invalid.example/app.apk'),
        throwsA(isA<DioException>()),
      );
      expect(File('${cache.path}/update.apk.tmp').existsSync(), isFalse);
      expect(await service.getDownloadedApk(), isNull);
    });
    test(
      'matching streamed SHA-256 publishes the APK without touching Pack files',
      () async {
        final bytes = List<int>.generate(256 * 1024, (i) => i % 251);
        final expected = hashes.sha256.convert(bytes).toString();
        final privatePack = await File(
          '${cache.path}/images.bgpack',
        ).writeAsBytes([7, 8, 9]);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          request.response.add(bytes.take(bytes.length ~/ 2).toList());
          await request.response.flush();
          request.response.add(bytes.skip(bytes.length ~/ 2).toList());
          await request.response.close();
        });
        final file = await service.downloadApk(
          'http://127.0.0.1:${server.port}/app.apk',
          expectedSha256: expected,
        );
        expect(
          await hashes.sha256.bind(file.openRead()).first,
          hashes.sha256.convert(bytes),
        );
        expect((await service.getDownloadedApk())?.path, file.path);
        expect(File('${cache.path}/update.apk.tmp').existsSync(), isFalse);
        expect(await privatePack.readAsBytes(), [7, 8, 9]);
      },
    );

    test(
      'checksum mismatch never publishes an installable APK and preserves other files',
      () async {
        final keep = await File(
          '${cache.path}/images.bgpack',
        ).writeAsBytes([9]);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          request.response.add([1, 2, 3]);
          await request.response.close();
        });
        await expectLater(
          service.downloadApk(
            'http://127.0.0.1:${server.port}/app.apk',
            expectedSha256: '0' * 64,
          ),
          throwsFormatException,
        );
        expect(await service.getDownloadedApk(), isNull);
        expect(File('${cache.path}/update.apk.tmp').existsSync(), isFalse);
        expect(await keep.readAsBytes(), [9]);
      },
    );

    test(
      'invalid supplied checksum fails before network or cache mutation',
      () async {
        final existing = await File(
          '${cache.path}/update.apk',
        ).writeAsString('previous complete APK');
        final dio = Dio();
        var requests = 0;
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests++;
              handler.reject(DioException(requestOptions: options));
            },
          ),
        );
        service = OtaInstallerService(
          dio: dio,
          temporaryDirectory: () async => cache,
        );
        for (final digest in ['', '1234', 'g' * 64, ' ${'a' * 64}']) {
          await expectLater(
            service.downloadApk(
              'https://invalid.example/app.apk',
              expectedSha256: digest,
            ),
            throwsFormatException,
          );
        }
        expect(requests, 0);
        expect(await existing.readAsString(), 'previous complete APK');
      },
    );

    test(
      'cancel during cache lookup cannot lose its token or start a later request',
      () async {
        final lookup = Completer<Directory>();
        final dio = Dio();
        var requests = 0;
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests++;
              handler.reject(DioException(requestOptions: options));
            },
          ),
        );
        service = OtaInstallerService(
          dio: dio,
          temporaryDirectory: () => lookup.future,
        );
        final pending = service.downloadApk(
          'https://invalid.example/app.apk',
          expectedSha256: 'a' * 64,
        );
        final rejected = expectLater(
          pending,
          throwsA(
            isA<DioException>().having(
              (e) => e.type,
              'type',
              DioExceptionType.cancel,
            ),
          ),
        );
        service.cancelDownload();
        await expectLater(
          service.downloadApk('https://invalid.example/second.apk'),
          throwsStateError,
        );
        lookup.complete(cache);
        await rejected;
        expect(requests, 0);
        expect(await service.getDownloadedApk(), isNull);
      },
    );

    test(
      'storage failure removes partial APK and allows a later retry',
      () async {
        final dio = Dio();
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) async {
              await File(
                '${cache.path}/update.apk.tmp',
              ).writeAsString('partial');
              handler.reject(
                DioException(
                  requestOptions: options,
                  error: const FileSystemException(
                    'No space left',
                    '',
                    OSError('', 28),
                  ),
                ),
              );
            },
          ),
        );
        service = OtaInstallerService(
          dio: dio,
          temporaryDirectory: () async => cache,
        );
        await expectLater(
          service.downloadApk(
            'https://invalid.example/app.apk',
            expectedSha256: 'a' * 64,
          ),
          throwsA(isA<DioException>()),
        );
        expect(await service.getDownloadedApk(), isNull);
        expect(File('${cache.path}/update.apk.tmp').existsSync(), isFalse);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          request.response.add([4, 5]);
          await request.response.close();
        });
        dio.interceptors.clear();
        final file = await service.downloadApk(
          'http://127.0.0.1:${server.port}/app.apk',
          expectedSha256: hashes.sha256.convert([4, 5]).toString(),
        );
        expect(await file.readAsBytes(), [4, 5]);
      },
    );
  });
}
