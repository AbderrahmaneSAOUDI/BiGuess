import 'card_image.dart';

/// Progress for the current image; preparing a batch never requires reading all
/// selected files into memory. Fractions are local work estimates, not uploads.
class ImagePreparationProgress {
  const ImagePreparationProgress({required this.stage, required this.fraction});
  final String stage;
  final double fraction;
}

class ImagePreparationFailure implements Exception {
  const ImagePreparationFailure(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

/// Shared cancellation for one selection/preparation session. Cancellation is
/// sticky, idempotent, and aborts the active browser preparation operation.
class ImagePreparationCancellation {
  bool _cancelled = false;
  final _listeners = <void Function()>{};
  bool get isCancelled => _cancelled;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final callbacks = _listeners.toList();
    _listeners.clear();
    for (final callback in callbacks) {
      callback();
    }
  }

  void addListener(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);
  void throwIfCancelled() {
    if (_cancelled) {
      throw const ImagePreparationFailure(
        'cancelled',
        'Image preparation cancelled.',
      );
    }
  }
}

/// A lazy handle to a user-selected file. It owns no decoded pixels or result
/// bytes until prepare is called, and dispose releases the browser File handle.
abstract interface class ImagePreparationSource {
  String get filename;
  int get size;
  Future<CardImage> prepare({
    void Function(ImagePreparationProgress)? onProgress,
    ImagePreparationCancellation? cancellation,
  });
  void dispose();
}
