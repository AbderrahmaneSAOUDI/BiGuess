import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'card_image.dart';

/// One user-selected file, retained only as a local draft attachment. No upload.
Future<CardImage?> pickCardImage() {
  final result = Completer<CardImage?>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = 'image/jpeg,image/png,image/webp'
    ..multiple = false;
  input.style.display = 'none';
  void finish(CardImage? image, [Object? error]) {
    input.remove();
    if (result.isCompleted) return;
    if (error != null) {
      result.completeError(error);
    } else {
      result.complete(image);
    }
  }

  input.addEventListener(
    'cancel',
    ((web.Event _) => finish(null)).toJS,
    web.AddEventListenerOptions(once: true),
  );
  input.addEventListener(
    'change',
    ((web.Event _) {
      unawaited(() async {
        try {
          final file = input.files?.item(0);
          if (file == null) {
            finish(null);
            return;
          }
          if (file.size > CardImage.maxBytes) {
            throw const FormatException(
              'Select an image no larger than 5 MiB.',
            );
          }
          final buffer = await file.arrayBuffer().toDart;
          final image = CardImage(
            filename: file.name,
            mimeType: file.type,
            base64: base64Encode(buffer.toDart.asUint8List()),
          );
          // Reuse persisted-attachment validation before displaying or saving it.
          finish(CardImage.fromJson(image.toJson()));
        } catch (error) {
          finish(null, error);
        }
      }());
    }).toJS,
    web.AddEventListenerOptions(once: true),
  );
  web.document.body!.append(input);
  input.click();
  return result.future;
}
