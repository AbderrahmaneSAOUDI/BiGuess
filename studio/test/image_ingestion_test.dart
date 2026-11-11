import 'dart:async';
import 'dart:convert';

import 'package:biguess_studio/data/card_image.dart';
import 'package:biguess_studio/data/dataset_api.dart';
import 'package:biguess_studio/data/image_ingestion.dart';
import 'package:biguess_studio/data/studio_dataset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'card_model_test.dart' show pixelPng;

CardImage preparedUploadImage({
  String hash =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
}) => CardImage(
  filename: 'Ada.png',
  mimeType: 'image/png',
  base64: pixelPng,
  preparation: ImagePreparationInfo(sha256: hash, width: 1, height: 1),
);

Map<String, Object?> uploadReceiptJson({
  String packId = 'pack-a',
  CardImage? image,
}) {
  final candidate = image ?? preparedUploadImage();
  return {
    'protocolVersion': 1,
    'imageIngestionVersion': 1,
    'packId': packId,
    'imageReference': 'objects/${'b' * 64}.png',
    'sha256': candidate.preparation!.sha256,
    'byteLength': candidate.bytes.length,
    'contentType': candidate.mimeType,
    'width': 1,
    'height': 1,
  };
}

Matcher apiFailure(String code) =>
    isA<DatasetApiFailure>().having((error) => error.code, 'code', code);

class _AbortClient extends http.BaseClient {
  final started = Completer<void>();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    started.complete();
    await (request as http.AbortableRequest).abortTrigger;
    throw http.RequestAbortedException(request.url);
  }
}

void main() {
  test('private upload sends exact normalized bytes, bearer, hash and Pack precondition', () async {
    final image = preparedUploadImage();
    final api = WorkerImageIngestionApi(
      Uri.parse('https://api.example/ignored'),
      MockClient((request) async {
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'https://api.example/studio/v1/packs/pack%2Fa/images',
        );
        expect(request.headers['authorization'], 'Bearer verified-token');
        expect(request.headers['content-type'], 'image/png');
        expect(request.headers['x-content-sha256'], image.preparation!.sha256);
        expect(request.headers['if-match'], '"rev-7"');
        expect(request.bodyBytes, image.bytes);
        return http.Response(
          jsonEncode(uploadReceiptJson(packId: 'pack/a')),
          200,
        );
      }),
    );
    final receipt = await api.upload(
      'verified-token',
      'pack/a',
      7,
      image,
      () => true,
      cancelled: Completer<void>().future,
    );
    expect(receipt.matches('pack/a', image), isTrue);
    api.close();
  });

  test(
    'upload accepts only a strict receipt for the exact prepared candidate',
    () async {
      final good = uploadReceiptJson();
      for (final invalid in <Object?>[
        {...good, 'protocolVersion': 2},
        {...good, 'imageIngestionVersion': 2},
        {...good, 'packId': 'foreign'},
        {...good, 'sha256': 'c' * 64},
        {...good, 'byteLength': (good['byteLength']! as int) + 1},
        {...good, 'contentType': 'image/webp'},
        {...good, 'width': 2},
        {...good, 'height': 0},
        {...good, 'width': 1.0},
        {...good, 'imageReference': 'https://public.example/image.png'},
        {...good, 'imageReference': 'objects/${'b' * 64}.webp'},
        {...good, 'bucketWriteToken': 'forged'},
        <Object?>[],
        null,
      ]) {
        final api = WorkerImageIngestionApi(
          Uri.parse('https://api.example'),
          MockClient((_) async => http.Response(jsonEncode(invalid), 200)),
        );
        await expectLater(
          api.upload(
            'token',
            'pack-a',
            1,
            preparedUploadImage(),
            () => true,
            cancelled: Completer<void>().future,
          ),
          throwsA(apiFailure('invalid-image-receipt')),
        );
        api.close();
      }
    },
  );

  test('upload translates auth, scope, revision, quota and format denials without accepting receipts', () async {
    for (final failure in {
      401: 'session-expired',
      403: 'forbidden',
      404: 'image-pack-unavailable',
      412: 'draft-conflict',
      413: 'image-too-large',
      429: 'image-quota',
      400: 'image-rejected',
      415: 'image-rejected',
      422: 'image-rejected',
      503: 'image-upload-unavailable',
    }.entries) {
      final api = WorkerImageIngestionApi(
        Uri.parse('https://api.example'),
        MockClient((_) async => http.Response('{}', failure.key)),
      );
      await expectLater(
        api.upload(
          'token',
          'pack-a',
          1,
          preparedUploadImage(),
          () => true,
          cancelled: Completer<void>().future,
        ),
        throwsA(apiFailure(failure.value)),
      );
      api.close();
    }
  });

  test('temporary upload pressure and interrupted bodies suggest retry, not quota relief', () async {
    for (final failure in [
      (429, 'rate_limited', 'image-upload-busy'),
      (400, 'upload_interrupted', 'image-upload-interrupted'),
      (408, 'upload_interrupted', 'image-upload-interrupted'),
    ]) {
      final api = WorkerImageIngestionApi(
        Uri.parse('https://api.example'),
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'protocolVersion': 1,
              'error': {'code': failure.$2},
            }),
            failure.$1,
          ),
        ),
      );
      await expectLater(
        api.upload(
          'token',
          'pack-a',
          1,
          preparedUploadImage(),
          () => true,
          cancelled: Completer<void>().future,
        ),
        throwsA(apiFailure(failure.$3)),
      );
      api.close();
    }
  });

  test(
    'unprepared and detached candidates cannot start network requests',
    () async {
      var calls = 0;
      final api = WorkerImageIngestionApi(
        Uri.parse('https://api.example'),
        MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        api.upload(
          'token',
          'pack-a',
          1,
          CardImage(
            filename: 'old.png',
            mimeType: 'image/png',
            base64: pixelPng,
          ),
          () => true,
          cancelled: Completer<void>().future,
        ),
        throwsA(apiFailure('image-not-prepared')),
      );
      await expectLater(
        api.upload(
          'token',
          'pack-a',
          1,
          preparedUploadImage(),
          () => false,
          cancelled: Completer<void>().future,
        ),
        throwsA(apiFailure('cancelled')),
      );
      expect(calls, 0);
      api.close();
    },
  );

  test(
    'in-flight cancellation aborts HTTP and does not return a late receipt',
    () async {
      final client = _AbortClient();
      final api = WorkerImageIngestionApi(
        Uri.parse('https://api.example'),
        client,
      );
      final cancelled = Completer<void>();
      var current = true;
      final result = api.upload(
        'token',
        'pack-a',
        1,
        preparedUploadImage(),
        () => current,
        cancelled: cancelled.future,
      );
      final assertion = expectLater(result, throwsA(apiFailure('cancelled')));
      await client.started.future;
      current = false;
      cancelled.complete();
      await assertion;
      api.close();
    },
  );

  test('receipt roundtrips as local operational data beside canonical fields and preview', () {
    final image = preparedUploadImage();
    final receipt = UploadedCardImage.fromJson(uploadReceiptJson());
    final draft = LocalDraft(
      id: '["card","card-a"]',
      resourceType: 'card',
      resourceId: 'card-a',
      action: 'create',
      value: {
        'name': 'Ada',
        'imageReference': receipt.imageReference,
        'difficulty': 2,
        'packId': 'pack-a',
      },
      localImage: image,
      uploadedImage: receipt,
    );
    final restored = LocalDraft.fromJson(
      Map<String, Object?>.from(jsonDecode(jsonEncode(draft.toJson())) as Map),
    );
    expect(restored.value.keys.toSet(), {
      'name',
      'imageReference',
      'difficulty',
      'packId',
    });
    expect(restored.uploadedImage!.toJson(), receipt.toJson());
    expect(
      restored.uploadedImage!.matches('pack-a', restored.localImage!),
      isTrue,
    );
    expect(
      restored.copyWith(status: DraftStatus.unsent).uploadedImage,
      same(restored.uploadedImage),
    );
    expect(restored.copyWith(clearUploadedImage: true).uploadedImage, isNull);
    expect(
      () => LocalDraft.fromJson({...draft.toJson(), 'localImage': null}),
      throwsFormatException,
    );
  });
}
