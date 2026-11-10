import 'dart:convert';

import 'package:biguess_studio/data/card_image.dart';
import 'package:biguess_studio/data/studio_dataset.dart';
import 'package:biguess_studio/data/image_preparation.dart';
import 'package:flutter_test/flutter_test.dart';

const pixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aV1QAAAAASUVORK5CYII=';
CardImage localPixel({String filename = 'Ada_Lovelace.png'}) =>
    CardImage(filename: filename, mimeType: 'image/png', base64: pixelPng);

void main() {
  test(
    'local image candidate roundtrips separately from canonical Card fields',
    () {
      final image = localPixel();
      final draft = LocalDraft(
        id: '["card","card"]',
        resourceType: 'card',
        resourceId: 'card',
        action: 'create',
        value: {
          'name': 'Ada',
          'imageReference': null,
          'difficulty': 2,
          'packId': 'pack',
        },
        localImage: image,
      );
      final restored = LocalDraft.fromJson(
        jsonDecode(jsonEncode(draft.toJson())) as Map<String, Object?>,
      );
      expect(restored.value.keys.toSet(), {
        'name',
        'imageReference',
        'difficulty',
        'packId',
      });
      expect(restored.localImage!.bytes, image.bytes);
      expect(restored.localImage!.suggestedName, 'Ada Lovelace');
      expect(
        restored.copyWith(status: DraftStatus.unsent).localImage!.base64,
        pixelPng,
      );
      expect(
        localPixel(filename: r'C:\fakepath\Jean-Luc_Picard.webp').suggestedName,
        'Jean Luc Picard',
      );
    },
  );

  test('local image envelope rejects unsupported unsafe oversized and mismatched candidates', () {
    for (final bad in [
      {'filename': 'bad.svg', 'mimeType': 'image/svg+xml', 'base64': pixelPng},
      {'filename': 'bad.jpg', 'mimeType': 'image/jpeg', 'base64': pixelPng},
      {'filename': 'bad.png', 'mimeType': 'image/png', 'base64': 'not-base64!'},
      {'filename': '', 'mimeType': 'image/png', 'base64': pixelPng},
      {
        'filename': 'bad\nname.png',
        'mimeType': 'image/png',
        'base64': pixelPng,
      },
      {
        'filename': 'bad.png',
        'mimeType': 'image/png',
        'base64': 'A' * (CardImage.maxBytes * 2),
      },
    ]) {
      expect(() => CardImage.fromJson(bad), throwsFormatException);
    }
    expect(
      () => CardImage.fromJson({
        ...localPixel().toJson(),
        'createdByUid': 'foreign',
      }),
      throwsFormatException,
    );
    final invalid = LocalDraft(
      id: 'x',
      resourceType: 'pack',
      resourceId: 'x',
      action: 'create',
      value: {},
      localImage: localPixel(),
    );
    expect(() => LocalDraft.fromJson(invalid.toJson()), throwsFormatException);
  });
  test('prepared metadata survives local draft reload without adding canonical Card fields', () {
    final info = ImagePreparationInfo(
      sha256:
          'b9974e82a2b76a9a8a3669acf7412620308a32674173021a2ccb1ca9c38d7e7d',
      width: 1,
      height: 1,
      warnings: ['above-size-target'],
      suggestedName: 'Normalized Ada',
    );
    final prepared = CardImage(
      filename: 'Ada.png',
      mimeType: 'image/png',
      base64: pixelPng,
      preparation: info,
    );
    final restored = CardImage.fromJson(
      jsonDecode(jsonEncode(prepared.toJson())) as Map<String, Object?>,
    );
    expect(restored.isPrepared, isTrue);
    expect(restored.preparation!.sha256, info.sha256);
    expect(restored.preparation!.width, 1);
    expect(restored.preparation!.warnings, ['above-size-target']);
    expect(restored.suggestedName, 'Normalized Ada');
    expect(
      () => restored.preparation!.warnings.add('mutated'),
      throwsUnsupportedError,
    );
    expect(CardImage.fromJson(localPixel().toJson()).isPrepared, isFalse);
  });

  test('preparation metadata rejects invalid hashes dimensions and hidden extra fields', () {
    final good = ImagePreparationInfo(
      sha256: 'a' * 64,
      width: 100,
      height: 50,
    ).toJson();
    for (final invalid in [
      {...good, 'sha256': 'not-a-digest'},
      {...good, 'width': 0},
      {...good, 'height': 4097},
      {...good, 'width': 1.0},
      {
        ...good,
        'warnings': [false],
      },
      {...good, 'createdByUid': 'foreign'},
      {...good, 'suggestedName': 'bad\u0085name'},
    ]) {
      expect(
        () => ImagePreparationInfo.fromJson(invalid),
        throwsFormatException,
      );
    }
  });

  test('filename suggestions remove paths unsafe controls separators and empty names', () {
    expect(
      imageNameSuggestion(r'C:\fakepath\Ada__Lovelace-final.PNG'),
      'Ada Lovelace final',
    );
    expect(imageNameSuggestion('folder/李_小龍.webp'), '李 小龍');
    expect(imageNameSuggestion('bad\u0000_\u0085name.png'), 'bad name');
    expect(imageNameSuggestion('_.png'), 'Untitled image');
    expect(imageNameSuggestion('${'a' * 140}.jpeg').runes.length, 120);
  });

  test(
    'cancellation is sticky idempotent and releases listener references',
    () {
      final cancellation = ImagePreparationCancellation();
      var aborts = 0;
      void abort() => aborts++;
      cancellation.addListener(abort);
      cancellation.cancel();
      cancellation.cancel();
      expect(aborts, 1);
      expect(cancellation.isCancelled, isTrue);
      expect(
        cancellation.throwIfCancelled,
        throwsA(
          isA<ImagePreparationFailure>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
      cancellation.addListener(abort);
      expect(aborts, 2);
      final removed = ImagePreparationCancellation();
      removed.addListener(abort);
      removed.removeListener(abort);
      removed.cancel();
      expect(aborts, 2);
    },
  );
}
