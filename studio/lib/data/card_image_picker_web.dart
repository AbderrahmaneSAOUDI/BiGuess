import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'card_image.dart';
import 'image_preparation.dart';

@JS('biguessImages')
external _ImageEngine? get _engine;

extension type _ImageEngine(JSObject _) implements JSObject {
  external JSPromise<_PreparedImage> prepare(
    web.File file,
    _PrepareOptions options,
  );
}

extension type _PrepareOptions._(JSObject _) implements JSObject {
  external factory _PrepareOptions({
    JSFunction? onProgress,
    web.AbortSignal? signal,
  });
}

extension type _PreparedImage(JSObject _) implements JSObject {
  external JSArrayBuffer get bytes;
  external JSString get mimeType;
  external JSString get filename;
  external JSString get suggestedName;
  external JSNumber get width;
  external JSNumber get height;
  external JSString get sha256;
  external JSArray<JSString> get warnings;
}

extension type _BrowserProgress(JSObject _) implements JSObject {
  external JSString get stage;
  external JSNumber get fraction;
}

extension type _BrowserFailure(JSObject _) implements JSObject {
  external JSString? get code;
  external JSString? get name;
}

const _messages = {
  'unsupported-browser': 'This browser cannot prepare images. Try a browser with image decoding and canvas support.',
  'invalid-input': 'Select a JPEG, PNG or WebP image.',
  'busy':
      'Another image is being prepared. Wait for it to finish or cancel it.',
  'image-too-large': 'This image exceeds the browser preparation limit. Choose a smaller source image.',
  'unsupported-format':
      'This image format is not supported. Choose JPEG, PNG or WebP.',
  'invalid-format': 'The image contents do not match a supported format.',
  'corrupt-image': 'This image could not be decoded. Choose a valid image.',
  'output-too-large': 'The prepared image exceeds the local storage limit. Choose a smaller source.',
  'invalid-output': 'The browser could not produce a valid prepared image.',
  'timeout':
      'Image preparation took too long. Retry or choose a smaller image.',
  'worker-failed': 'Image preparation stopped unexpectedly. Retry the image.',
  'memory-or-capability': 'This browser could not allocate enough image memory. Choose a smaller image or another browser.',
  'quota-exceeded': 'The browser ran out of image preparation storage. Free site storage or choose a smaller image, then retry.',
  'memory-limit': 'The browser ran out of image memory. Close other tabs or choose a smaller image, then retry.',
  'preparation-failed': 'The browser could not prepare this image. Check available memory or choose another image.',
  'cancelled': 'Image preparation cancelled.',
};

ImagePreparationFailure _failure(String code) => ImagePreparationFailure(
  code,
  _messages[code] ??
      'Could not prepare this image. Retry or choose another image.',
);

ImagePreparationFailure _browserFailure(Object error) {
  if (error is ImagePreparationFailure) return error;
  if (error is FormatException) return _failure('invalid-output');
  try {
    final value = error as JSAny;
    if (value.isA<JSObject>()) {
      final failure = _BrowserFailure(value as JSObject);
      if (failure.name?.toDart == 'AbortError') return _failure('cancelled');
      return _failure(failure.code?.toDart ?? 'invalid-output');
    }
  } catch (_) {
    // A Dart error is not a JavaScript rejection object.
  }
  return _failure('invalid-output');
}

class _BrowserImageSource implements ImagePreparationSource {
  _BrowserImageSource(web.File file)
    : _file = file,
      filename = file.name,
      size = file.size;
  web.File? _file;
  web.AbortController? _activeAbort;
  bool _preparing = false;
  @override
  final String filename;
  @override
  final int size;

  @override
  Future<CardImage> prepare({
    void Function(ImagePreparationProgress)? onProgress,
    ImagePreparationCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final file = _file;
    if (file == null) throw _failure('cancelled');
    if (_preparing) throw _failure('busy');
    if (size < 1 || size > 20 * 1024 * 1024) throw _failure('image-too-large');
    final engine = _engine;
    if (engine == null) throw _failure('unsupported-browser');
    _preparing = true;
    final abort = web.AbortController();
    _activeAbort = abort;
    void cancel() => abort.abort();
    cancellation?.addListener(cancel);
    try {
      final prepared = await engine
          .prepare(
            file,
            _PrepareOptions(
              signal: abort.signal,
              onProgress: ((_BrowserProgress progress) {
                if (cancellation?.isCancelled != true && _file != null) {
                  final fraction = progress.fraction.toDartDouble;
                  onProgress?.call(
                    ImagePreparationProgress(
                      stage: progress.stage.toDart,
                      fraction: fraction.isFinite ? fraction.clamp(0, 1) : 0,
                    ),
                  );
                }
              }).toJS,
            ),
          )
          .toDart;
      cancellation?.throwIfCancelled();
      if (_file == null) throw _failure('cancelled');
      final bytes = prepared.bytes.toDart.asUint8List();
      final mimeType = prepared.mimeType.toDart;
      final outputName = prepared.filename.toDart;
      final width = prepared.width.toDartInt;
      final height = prepared.height.toDartInt;
      if (bytes.isEmpty ||
          bytes.length > CardImage.maxBytes ||
          !{'image/webp', 'image/png'}.contains(mimeType) ||
          outputName.contains(RegExp(r'[/\\]')) ||
          prepared.width.toDartDouble != width ||
          prepared.height.toDartDouble != height ||
          width < 1 ||
          height < 1 ||
          width > 1024 ||
          height > 1024) {
        throw _failure('invalid-output');
      }
      final digest = await web.window.crypto.subtle
          .digest('SHA-256'.toJS, prepared.bytes)
          .toDart;
      cancellation?.throwIfCancelled();
      if (_file == null) throw _failure('cancelled');
      final sha256 = (digest as JSArrayBuffer).toDart
          .asUint8List()
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      if (sha256 != prepared.sha256.toDart) throw _failure('invalid-output');
      return CardImage(
        filename: outputName,
        mimeType: mimeType,
        base64: base64Encode(bytes),
        preparation: ImagePreparationInfo(
          sha256: sha256,
          width: width,
          height: height,
          warnings: prepared.warnings.toDart
              .map((warning) => warning.toDart)
              .toList(),
          suggestedName: prepared.suggestedName.toDart,
        ),
      );
    } catch (error) {
      throw _browserFailure(error);
    } finally {
      cancellation?.removeListener(cancel);
      _activeAbort = null;
      _preparing = false;
    }
  }

  @override
  void dispose() {
    _file = null;
    _activeAbort?.abort();
  }
}

Future<List<ImagePreparationSource>> _pickSources({required bool multiple}) {
  final result = Completer<List<ImagePreparationSource>>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = 'image/jpeg,image/png,image/webp'
    ..multiple = multiple;
  input.style.display = 'none';
  void finish(List<ImagePreparationSource> sources, [Object? error]) {
    input.remove();
    if (result.isCompleted) return;
    if (error == null) {
      result.complete(sources);
    } else {
      result.completeError(error);
    }
  }

  input.addEventListener(
    'cancel',
    ((web.Event _) => finish([])).toJS,
    web.AddEventListenerOptions(once: true),
  );
  input.addEventListener(
    'change',
    ((web.Event _) {
      final files = input.files;
      if (files == null || files.length == 0) {
        finish([]);
        return;
      }
      if (files.length > 500) {
        finish(
          [],
          const ImagePreparationFailure(
            'batch-too-large',
            'Select at most 500 images per preparation session.',
          ),
        );
        return;
      }
      finish([
        for (var i = 0; i < files.length; i++)
          _BrowserImageSource(files.item(i)!),
      ]);
    }).toJS,
    web.AddEventListenerOptions(once: true),
  );
  web.document.body!.append(input);
  input.click();
  return result.future;
}

/// File handles only; prepare sequentially and dispose each handle afterward.
Future<List<ImagePreparationSource>> pickImageSources() =>
    _pickSources(multiple: true);

/// The single-image Card editor uses the same normalization engine as batches.
Future<CardImage?> pickCardImage({
  void Function(ImagePreparationProgress)? onProgress,
  ImagePreparationCancellation? cancellation,
}) async {
  cancellation?.throwIfCancelled();
  final sources = await _pickSources(multiple: false);
  try {
    cancellation?.throwIfCancelled();
    if (sources.isEmpty) return null;
    return await sources.single.prepare(
      onProgress: onProgress,
      cancellation: cancellation,
    );
  } finally {
    for (final source in sources) {
      source.dispose();
    }
  }
}
