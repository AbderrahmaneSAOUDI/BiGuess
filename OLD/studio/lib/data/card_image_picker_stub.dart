import 'card_image.dart';
import 'image_preparation.dart';

Future<CardImage?> pickCardImage({
  void Function(ImagePreparationProgress)? onProgress,
  ImagePreparationCancellation? cancellation,
}) async => throw const ImagePreparationFailure(
  'unsupported-browser',
  'Browser image selection is unavailable.',
);

Future<List<ImagePreparationSource>> pickImageSources() async =>
    throw const ImagePreparationFailure(
      'unsupported-browser',
      'Browser image selection is unavailable.',
    );
