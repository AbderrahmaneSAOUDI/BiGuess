import 'card_image.dart';
import 'image_ingestion.dart';

class BulkImportItem {
  BulkImportItem({
    required this.id,
    required this.sourceFilename,
    required this.name,
    required this.difficulty,
    required this.image,
    this.uploadedImage,
    this.isDuplicate = false,
  });

  final String id;
  final String sourceFilename;
  String name;
  int difficulty;
  final CardImage image;
  UploadedCardImage? uploadedImage;
  bool isDuplicate;

  bool get isValid => name.trim().isNotEmpty && [1, 2, 3].contains(difficulty);

  String? get validationError {
    if (name.trim().isEmpty) return 'Name cannot be empty';
    if (![1, 2, 3].contains(difficulty)) return 'Difficulty must be 1, 2, or 3';
    return null;
  }
}

class BulkImportProgress {
  const BulkImportProgress({
    required this.stage,
    required this.current,
    required this.total,
    this.detail,
  });

  final String stage;
  final int current;
  final int total;
  final String? detail;

  double get fraction => total > 0 ? (current / total).clamp(0.0, 1.0) : 0.0;
}

class BulkImportResult {
  const BulkImportResult({
    required this.committedCount,
    required this.batchCount,
    required this.finalRevision,
  });

  final int committedCount;
  final int batchCount;
  final int finalRevision;
}
