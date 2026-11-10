import 'package:biguess_studio/data/studio_dataset.dart';
import 'package:biguess_studio/data/topic_taxonomy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'legacy T28 draft without action remains an update after additive decoding',
    () {
      final old = {
        'id': 'draft',
        'resourceType': 'pack',
        'resourceId': 'pack',
        'baseRevision': 1,
        'value': {'name': 'Draft'},
        'status': 'unsent',
        'publishedRevision': null,
      };
      final draft = LocalDraft.fromJson(old);
      expect(draft.action, 'update');
      expect(draft.status, DraftStatus.unsent);
      expect(LocalDraft.fromJson(draft.toJson()).action, 'update');
    },
  );
  test('all supported pending Topic operations roundtrip without changing their action', () {
    for (final action in [
      'create',
      'update',
      'hide',
      'softDelete',
      'restore',
    ]) {
      final draft = LocalDraft(
        id: 'id',
        resourceType: 'topic',
        resourceId: 'topic',
        action: action,
        value: {'name': 'Name'},
        baseRevision: action == 'create' ? null : 2,
      );
      final saved = LocalDraft.fromJson(draft.toJson());
      expect(saved.action, action);
      expect(saved.copyWith(status: DraftStatus.unsent).action, action);
    }
    expect(
      () => LocalDraft.fromJson({
        'id': 'x',
        'resourceType': 'topic',
        'resourceId': 'x',
        'value': {'name': 'x'},
        'status': 'draft',
        'action': 'publish',
      }),
      throwsFormatException,
    );
  });
  test('taxonomy picker excludes new deleted purged pending restore and conflict parents', () {
    TopicTaxonomy topic(
      String state,
      int revision, {
      String? action,
      DraftStatus status = DraftStatus.draft,
    }) => TopicTaxonomy(
      id: 'topic',
      name: 'Topic',
      state: state,
      revision: revision,
      pending: action == null
          ? null
          : LocalDraft(
              id: 'id',
              resourceType: 'topic',
              resourceId: 'topic',
              value: {'name': 'Topic'},
              action: action,
              status: status,
            ),
    );
    expect(topic('active', 1).eligible, isTrue);
    expect(topic('hidden', 1).eligible, isTrue);
    expect(topic('active', 0, action: 'create').eligible, isFalse);
    expect(topic('deleted', 1).eligible, isFalse);
    expect(topic('purged', 1).eligible, isFalse);
    expect(topic('hidden', 1, action: 'restore').eligible, isFalse);
    expect(topic('deleted', 1, action: 'softDelete').eligible, isFalse);
    expect(topic('hidden', 1, action: 'hide').eligible, isTrue);
    expect(
      topic(
        'active',
        1,
        action: 'update',
        status: DraftStatus.conflict,
      ).eligible,
      isFalse,
    );
  });
}
