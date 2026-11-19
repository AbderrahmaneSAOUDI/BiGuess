import 'dart:async';

import 'package:biguess_studio/auth/studio_session.dart';
import 'package:biguess_studio/data/dataset_api.dart';
import 'package:biguess_studio/data/dataset_controller.dart';
import 'package:biguess_studio/data/dataset_store.dart';
import 'package:biguess_studio/data/publication_api.dart';
import 'package:biguess_studio/data/studio_dataset.dart';
import 'package:flutter_test/flutter_test.dart';

import 'publication_api_test.dart' show publicationJson;

class _Identity implements StudioIdentity {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Authorization implements StudioAuthorization {
  int calls = 0;
  String role = 'owner_admin';
  @override
  Future<StudioPrincipal> lookup(String token) async {
    calls++;
    return StudioPrincipal('owner', 'owner@example.test', role);
  }
}

class _Session extends StudioSession {
  _Session(super.identity, super.authorization);
  @override
  String? tokenFor(String uid, String role) =>
      phase == SessionPhase.authorized ? 'verified' : null;
}

class _DatasetApi implements DatasetApi {
  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Publication implements PublicationApi {
  int calls = 0;
  Completer<PublicationReview>? pending;
  @override
  Future<PublicationReview> review(
    String token,
    String resourceType,
    String id,
    bool Function() current, {
    String? action,
    PublicationReview? expected,
    String? evidence,
  }) async {
    calls++;
    return pending?.future ?? PublicationReview.fromJson(publicationJson());
  }

  @override
  void close() {}
}

void main() {
  late _Authorization authorization;
  late _Session session;
  late _Publication publication;
  late DatasetController controller;
  setUp(() {
    authorization = _Authorization();
    session = _Session(_Identity(), authorization)
      ..phase = SessionPhase.authorized;
    publication = _Publication();
    controller =
        DatasetController(
            projectId: 'project',
            session: session,
            api: _DatasetApi(),
            publication: publication,
          )
          ..scope = const DatasetScope('project', 'owner', 'owner_admin')
          ..phase = DatasetPhase.ready;
    controller.snapshot = DatasetSnapshot(
      scope: controller.scope!,
      records: const [
        {
          'resourceType': 'topic',
          'id': 'topic',
          'state': 'active',
          'revision': 1,
        },
        {
          'resourceType': 'pack',
          'id': 'pack/id',
          'topicId': 'topic',
          'state': 'active',
          'revision': 3,
        },
      ],
    );
  });
  tearDown(() {
    controller.dispose();
    session.dispose();
  });
  Matcher failure(String code) =>
      isA<DatasetStorageFailure>().having((error) => error.code, 'code', code);

  test('own Pack Card drafts and Topic descendants block publication before any network call', () async {
    controller.snapshot = controller.snapshot!.copyWith(
      drafts: [
        LocalDraft(
          id: 'draft',
          resourceType: 'card',
          resourceId: 'card',
          value: const {'packId': 'pack/id'},
        ),
      ],
    );
    for (final target in [('pack', 'pack/id'), ('topic', 'topic')]) {
      await expectLater(
        controller.reviewPublication(target.$1, target.$2),
        throwsA(failure('publication-pending-changes')),
      );
    }
    expect(authorization.calls, 0);
    expect(publication.calls, 0);
  });

  test(
    'lifecycle drafts use stored parent relationships when values are empty',
    () async {
      controller.snapshot = controller.snapshot!.copyWith(
        records: [
          ...controller.snapshot!.records,
          {
            'resourceType': 'card',
            'id': 'stored-card',
            'packId': 'pack/id',
            'state': 'active',
            'revision': 3,
          },
        ],
      );
      for (final draft in [
        LocalDraft(
          id: 'hide-card',
          resourceType: 'card',
          resourceId: 'stored-card',
          action: 'hide',
          value: const {},
        ),
        LocalDraft(
          id: 'hide-pack',
          resourceType: 'pack',
          resourceId: 'pack/id',
          action: 'hide',
          value: const {},
        ),
      ]) {
        controller.snapshot = controller.snapshot!.copyWith(drafts: [draft]);
        await expectLater(
          controller.reviewPublication('topic', 'topic'),
          throwsA(failure('publication-pending-changes')),
        );
        await expectLater(
          controller.reviewPublication('pack', 'pack/id'),
          throwsA(failure('publication-pending-changes')),
        );
      }
      expect(authorization.calls, 0);
      expect(publication.calls, 0);
    },
  );

  test('offline workspace cannot approve or publish', () async {
    controller.phase = DatasetPhase.offline;
    await expectLater(
      controller.reviewPublication('pack', 'pack/id'),
      throwsA(failure('publication-offline')),
    );
    expect(authorization.calls, 0);
    expect(publication.calls, 0);
  });

  test(
    'every action verifies live role before sending publication content',
    () async {
      authorization.role = 'collector';
      await expectLater(
        controller.reviewPublication(
          'pack',
          'pack/id',
          action: 'publish',
          expected: PublicationReview.fromJson(publicationJson()),
        ),
        throwsA(failure('cancelled')),
      );
      expect(authorization.calls, 1);
      expect(publication.calls, 0);
    },
  );

  test('draft created during network review invalidates late result', () async {
    publication.pending = Completer<PublicationReview>();
    final pending = controller.reviewPublication('pack', 'pack/id');
    await Future<void>.delayed(Duration.zero);
    controller.snapshot = controller.snapshot!.copyWith(
      drafts: [
        LocalDraft(
          id: 'draft',
          resourceType: 'card',
          resourceId: 'card',
          value: const {'packId': 'pack/id'},
        ),
      ],
    );
    publication.pending!.complete(
      PublicationReview.fromJson(publicationJson()),
    );
    await expectLater(pending, throwsA(failure('cancelled')));
  });
}
