import 'dart:convert';

import 'package:biguess_studio/data/card_image.dart';
import 'package:biguess_studio/data/studio_dataset.dart';
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
}
