import 'studio_dataset.dart';

/// Local working projection. Attribution is readonly and absent in Collector
/// records; membership in a server-scoped dataset authorizes their own edits.
class PackSummary {
  const PackSummary({
    required this.id,
    required this.name,
    required this.topicId,
    required this.state,
    required this.revision,
    required this.eligibleCardCount,
    this.pending,
    this.createdByUid,
    this.parentEligible = true,
  });
  final String id;
  final String name;
  final String topicId;
  final String state;
  final int revision;
  final int eligibleCardCount;
  final LocalDraft? pending;
  final String? createdByUid;
  final bool parentEligible;
  bool get isDraft => eligibleCardCount == 0;
  bool get playable =>
      !isDraft &&
      parentEligible &&
      {'active', 'hidden'}.contains(state) &&
      pending?.status != DraftStatus.conflict &&
      !{'softDelete', 'restore', 'permanentDelete'}.contains(pending?.action);
}
