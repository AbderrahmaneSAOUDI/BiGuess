import 'studio_dataset.dart';

/// Explicit minimal classification projection. It never carries attribution,
/// audit, child IDs or other administrative metadata to a Collector widget.
class TopicTaxonomy {
  const TopicTaxonomy({
    required this.id,
    required this.name,
    required this.state,
    required this.revision,
    this.pending,
  });
  final String id;
  final String name;
  final String state;
  final int revision;
  final LocalDraft? pending;

  /// Packs may reference only an existing, nondeleted server Topic. Hidden
  /// taxonomy remains permitted; an uncommitted new Topic is never a parent.
  bool get eligible =>
      revision > 0 &&
      {'active', 'hidden'}.contains(state) &&
      pending?.status != DraftStatus.conflict &&
      !{'softDelete', 'restore'}.contains(pending?.action);
}
