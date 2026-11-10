import 'card_image.dart';
import 'studio_dataset.dart';

/// Canonical Card content with separate readonly operational state for review.
class CardSummary {
  const CardSummary({
    required this.id,
    required this.name,
    required this.imageReference,
    required this.difficulty,
    required this.packId,
    required this.state,
    required this.revision,
    this.pending,
    this.createdByUid,
  });
  final String id;
  final String name;
  final String? imageReference;
  final int difficulty;
  final String packId;
  final String state;
  final int revision;
  final LocalDraft? pending;
  final String? createdByUid;
  CardImage? get localImage => pending?.localImage;
}
