import 'dart:async';

import 'package:biguess_studio/auth/studio_session.dart';
import 'package:biguess_studio/data/dataset_api.dart';
import 'package:biguess_studio/data/dataset_controller.dart';
import 'package:biguess_studio/data/dataset_store.dart';
import 'package:biguess_studio/data/indexed_db_dataset_store.dart';
import 'package:biguess_studio/data/offline_access_policy.dart';
import 'package:biguess_studio/data/studio_dataset.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dataset_test_factory_stub.dart'
    if (dart.library.js_interop) 'support/dataset_test_factory_web.dart';

class _Identity implements StudioIdentity {
  String? uid = 'a';
  final stream = StreamController<String?>.broadcast(sync: true);
  @override
  Stream<String?> get changes => stream.stream;
  @override
  Future<void> restore() async {}
  @override
  Future<String?> token({bool refresh = false}) async =>
      uid == null ? null : 'token-$uid';
  @override
  Future<void> popup() async {}
  @override
  Future<void> redirect() async {}
  @override
  Future<void> signOut() async {
    uid = null;
    stream.add(null);
  }
}

class _Authorization implements StudioAuthorization {
  _Authorization(this.identity);
  final _Identity identity;
  String role = 'collector';
  String? failure;
  int calls = 0;
  void Function()? afterLookup;
  @override
  Future<StudioPrincipal> lookup(String token) async {
    calls++;
    if (failure != null) throw SessionFailure(failure!);
    final uid = token.substring('token-'.length);
    final principal = StudioPrincipal(uid, '$uid@example.test', role);
    afterLookup?.call();
    return principal;
  }
}

class _RevokeFailure implements DatasetStore {
  _RevokeFailure(this.delegate);
  final DatasetStore delegate;
  @override
  Future<void> authorize(DatasetScope scope) => delegate.authorize(scope);
  @override
  Future<DatasetScope?> offlineScope(String project, String uid) =>
      delegate.offlineScope(project, uid);
  @override
  Future<DatasetSnapshot?> read(DatasetScope scope) => delegate.read(scope);
  @override
  Future<DatasetSnapshot> save(
    DatasetSnapshot snapshot, {
    required int expectedVersion,
  }) => delegate.save(snapshot, expectedVersion: expectedVersion);
  @override
  Future<void> revoke(String project, String uid) async =>
      throw const DatasetStorageFailure('storage-blocked');
  @override
  void close() => delegate.close();
}

class _Api implements DatasetApi {
  Future<InitialDataset> Function(String, bool Function())? handler;
  int calls = 0;
  final tokens = <String>[];
  bool closed = false;
  @override
  Future<InitialDataset> initial(String token, bool Function() current) async {
    calls++;
    tokens.add(token);
    return handler?.call(token, current) ??
        InitialDataset(
          records(token.endsWith('b') ? 'b' : 'a'),
          'opaque-resume',
        );
  }

  @override
  void close() {
    closed = true;
  }
}

List<Map<String, Object?>> records(String uid, {int revision = 1}) => [
  {
    'resourceType': 'topic',
    'id': 'topic',
    'name': 'Taxonomy',
    'state': 'hidden',
    'revision': 1,
  },
  {
    'resourceType': 'pack',
    'id': 'pack-$uid',
    'topicId': 'topic',
    'name': 'Private $uid',
    'state': 'active',
    'revision': revision,
  },
];
Matcher storageFailure(String code) =>
    isA<DatasetStorageFailure>().having((e) => e.code, 'code', code);
Future<void> waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for dataset state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Future<void> flush() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  final factory = datasetTestFactory();
  late _Identity identity;
  late _Authorization authorization;
  late _Api api;
  late StudioSession session;
  late DatasetController controller;
  late String dbName;
  late List<IndexedDbDatasetStore> handles;
  late bool online;
  late bool quota;
  late bool failRevoke;
  late bool factoryFailure;
  DatasetStore store() {
    if (factoryFailure) throw const DatasetStorageFailure('storage-blocked');
    final handle = IndexedDbDatasetStore(
      factory,
      databaseName: dbName,
      beforeSaveCommit: () {
        if (quota) throw const DatasetStorageFailure('quota-exceeded');
      },
    );
    handles.add(handle);
    return failRevoke ? _RevokeFailure(handle) : handle;
  }

  DatasetController createController() => DatasetController(
    projectId: 'project',
    session: session,
    api: api,
    storeFactory: store,
  );
  Future<void> connect() async {
    await session.validate();
    await waitFor(
      () =>
          controller.snapshot != null && controller.phase == DatasetPhase.ready,
    );
  }

  setUp(() {
    online = true;
    quota = false;
    failRevoke = false;
    factoryFailure = false;
    handles = [];
    dbName = 'controller-${DateTime.now().microsecondsSinceEpoch}';
    identity = _Identity();
    authorization = _Authorization(identity);
    api = _Api();
    session = StudioSession(identity, authorization, online: () => online);
    controller = createController()..start();
  });
  tearDown(() async {
    controller.dispose();
    session.dispose();
    await identity.stream.close();
    for (final handle in handles) {
      handle.close();
    }
    await factory.deleteDatabase(dbName);
  });

  test('initial sync promotes only after the complete dataset is returned and saved', () async {
    final incoming = Completer<InitialDataset>();
    api.handler = (_, _) => incoming.future;
    await session.validate();
    await waitFor(() => api.calls == 1);
    expect(controller.phase, DatasetPhase.loading);
    expect(controller.snapshot, isNull);
    final check = store();
    expect(
      await check.read(const DatasetScope('project', 'a', 'collector')),
      isNull,
    );
    incoming.complete(InitialDataset(records('a'), 'complete-resume'));
    await waitFor(() => controller.phase == DatasetPhase.ready);
    expect(controller.snapshot!.records.last['name'], 'Private a');
    expect(controller.snapshot!.resumeCursor, 'complete-resume');
    expect(controller.snapshot!.lastSyncedAt, isNotNull);
    expect(
      (await check.read(controller.scope!))!.records,
      controller.snapshot!.records,
    );
  });

  test('interrupted refresh preserves last complete snapshot and durable pending edits', () async {
    await connect();
    await controller.saveDraft(
      controller.snapshot!.records.last,
      name: 'Unsent local edit',
    );
    final saved = controller.snapshot!;
    api.handler = (_, _) async =>
        throw const DatasetApiFailure('sync-unavailable');
    await controller.refresh();
    expect(controller.phase, DatasetPhase.ready);
    expect(controller.errorCode, 'sync-unavailable');
    expect(controller.snapshot!.toJson(), saved.toJson());
    expect((await store().read(controller.scope!))!.toJson(), saved.toJson());
  });

  test('late previous-account sync result cannot promote after sign-out or account switch', () async {
    final pending = Completer<InitialDataset>();
    api.handler = (_, _) => pending.future;
    await session.validate();
    await waitFor(() => api.calls == 1);
    final oldEpoch = controller.scope!.namespace;
    final logout = session.logout();
    expect(controller.scope, isNull);
    expect(controller.snapshot, isNull);
    await logout;
    pending.complete(InitialDataset(records('a'), 'late-a'));
    await flush();
    expect(controller.snapshot, isNull);
    expect(await store().offlineScope('project', 'a'), isNull);
    await session.signIn();
    identity.uid = 'b';
    session.identityUid = 'b';
    api.handler = (_, _) async => InitialDataset(records('b'), 'resume-b');
    await connect();
    expect(controller.scope!.uid, 'b');
    expect(controller.scope!.namespace, isNot(oldEpoch));
    expect(controller.snapshot!.records.last['id'], 'pack-b');
    expect(controller.snapshot!.drafts, isEmpty);
  });

  test(
    'offline first login cannot open an empty or unverified browser cache',
    () async {
      online = false;
      session.identityUid = 'a';
      await session.validate();
      await waitFor(() => controller.phase == DatasetPhase.error);
      expect(controller.errorCode, 'offline-unavailable');
      expect(controller.scope, isNull);
      expect(controller.snapshot, isNull);
      expect(authorization.calls, 0);
      expect(api.calls, 0);
    },
  );

  test('restored same-account offline workspace can edit and queue across controller reload', () async {
    await connect();
    final calls = api.calls;
    online = false;
    await session.validate();
    await waitFor(() => controller.phase == DatasetPhase.offline);
    await controller.saveDraft(
      controller.snapshot!.records.last,
      name: 'Offline durable draft',
    );
    final id = controller.snapshot!.drafts.single.id;
    await controller.queueDraft(id);
    expect(controller.snapshot!.drafts.single.status, DraftStatus.unsent);
    controller.dispose();
    api = _Api();
    controller = createController()..start();
    await waitFor(() => controller.phase == DatasetPhase.offline);
    expect(
      controller.snapshot!.drafts.single.value['name'],
      'Offline durable draft',
    );
    expect(controller.snapshot!.drafts.single.status, DraftStatus.unsent);
    expect(api.calls, 0);
    expect(calls, 1);
  });

  test('reconnect authorization denial clears content and blocks another offline reopen', () async {
    await connect();
    online = false;
    await session.validate();
    await waitFor(() => controller.phase == DatasetPhase.offline);
    online = true;
    authorization.failure = 'forbidden';
    final pending = session.validate(refresh: true);
    expect(controller.scope, isNull);
    expect(controller.snapshot, isNull);
    await pending;
    await flush();
    expect(session.phase, SessionPhase.denied);
    expect(controller.snapshot, isNull);
    await waitFor(() => handles.isNotEmpty);
    online = false;
    await session.validate();
    await waitFor(() => controller.phase == DatasetPhase.error);
    expect(controller.errorCode, 'offline-unavailable');
    expect(controller.snapshot, isNull);
  });

  test('stale token returned by dataset API invalidates session and saved offline permission', () async {
    await connect();
    api.handler = (_, _) async =>
        throw const DatasetApiFailure('session-expired');
    await controller.refresh();
    await flush();
    expect(session.phase, SessionPhase.error);
    expect(session.errorCode, 'session-expired');
    expect(controller.snapshot, isNull);
    expect(await store().offlineScope('project', 'a'), isNull);
  });

  test('role downgrade starts separate dataset and never loads Owner records or queue', () async {
    authorization.role = 'owner_admin';
    await connect();
    await controller.saveDraft(
      controller.snapshot!.records.last,
      name: 'Owner pending',
    );
    final ownerNamespace = controller.scope!.namespace;
    authorization.role = 'collector';
    api.handler = (_, _) async =>
        InitialDataset(records('a'), 'collector-resume');
    await controller.refresh();
    expect(controller.scope!.role, 'collector');
    expect(controller.scope!.namespace, isNot(ownerNamespace));
    expect(controller.snapshot!.drafts, isEmpty);
    expect(api.calls, 2);
    expect((await store().offlineScope('project', 'a'))!.role, 'collector');
  });

  test('changed remote revision marks saved local draft conflict without dropping its content', () async {
    await connect();
    await controller.saveDraft(
      controller.snapshot!.records.last,
      name: 'Keep my edit',
    );
    final id = controller.snapshot!.drafts.single.id;
    await controller.queueDraft(id);
    api.handler = (_, _) async =>
        InitialDataset(records('a', revision: 2), 'new-resume');
    await controller.refresh();
    expect(controller.snapshot!.records.last['revision'], 2);
    final draft = controller.snapshot!.drafts.single;
    expect(draft.status, DraftStatus.conflict);
    expect(draft.value['name'], 'Keep my edit');
    expect(draft.baseRevision, 1);
    await expectLater(
      controller.queueDraft(id),
      throwsA(storageFailure('draft-conflict')),
    );
    expect(controller.snapshot!.drafts.single.status, DraftStatus.conflict);
  });

  test(
    'quota rollback keeps old snapshot and draft, then retry saves safely',
    () async {
      await connect();
      final before = controller.snapshot!.toJson();
      quota = true;
      await expectLater(
        controller.saveDraft(
          controller.snapshot!.records.last,
          name: 'Retry me',
        ),
        throwsA(storageFailure('quota-exceeded')),
      );
      expect(controller.errorCode, 'quota-exceeded');
      expect(controller.snapshot!.toJson(), before);
      expect((await store().read(controller.scope!))!.toJson(), before);
      quota = false;
      await controller.saveDraft(
        controller.snapshot!.records.last,
        name: 'Retry me',
      );
      expect(controller.snapshot!.drafts.single.value['name'], 'Retry me');
      expect(controller.errorCode, isNull);
    },
  );

  test(
    'another tab CAS conflict cannot overwrite a durable newer draft',
    () async {
      await connect();
      final stale = controller.snapshot!;
      final other = store();
      final current = (await other.read(controller.scope!))!;
      final next = await other.save(
        current.copyWith(
          drafts: [
            LocalDraft(
              id: 'other-tab',
              resourceType: 'pack',
              resourceId: 'pack-a',
              baseRevision: 1,
              value: {'name': 'Other tab draft'},
            ),
          ],
        ),
        expectedVersion: current.version,
      );
      await expectLater(
        controller.saveDraft(stale.records.last, name: 'Stale write'),
        throwsA(storageFailure('storage-conflict')),
      );
      expect(controller.errorCode, 'storage-conflict');
      expect(controller.snapshot!.version, stale.version);
      expect((await other.read(controller.scope!))!.toJson(), next.toJson());
    },
  );

  test('collector rejects cached privileged attribution and never renders the malformed dataset', () async {
    final seeded = store();
    const scope = DatasetScope('project', 'a', 'collector');
    OfflineAccessPolicy().allow(scope.project, scope.uid);
    await seeded.authorize(scope);
    await seeded.save(
      DatasetSnapshot(
        scope: scope,
        records: [...records('a')..last['createdByUid'] = 'b'],
        resumeCursor: 'r',
        lastSyncedAt: DateTime.now().toUtc(),
      ),
      expectedVersion: 0,
    );
    await session.validate();
    await waitFor(() => controller.phase == DatasetPhase.error);
    expect(controller.snapshot, isNull);
    expect(controller.scope, isNull);
    expect(controller.errorCode, 'invalid-dataset');
    expect(api.calls, 0);
  });
  test(
    'failed persistent revocation cannot reopen known-denied content offline',
    () async {
      await connect();
      failRevoke = true;
      authorization.failure = 'forbidden';
      await session.validate(refresh: true);
      await flush();
      expect(session.phase, SessionPhase.denied);
      // The failure really left the old database receipt present and readable.
      expect((await store().offlineScope('project', 'a'))?.uid, 'a');
      online = false;
      await session.validate();
      await waitFor(() => controller.phase == DatasetPhase.error);
      expect(controller.snapshot, isNull);
      expect(controller.scope, isNull);
    },
  );

  test('transient factory failure during logout cleanup does not poison later retries', () async {
    await connect();
    factoryFailure = true;
    await session.logout();
    await flush();
    expect(controller.snapshot, isNull);
    factoryFailure = false;
    await session.signIn();
    identity.uid = 'a';
    session.identityUid = 'a';
    await connect();
    expect(controller.phase, DatasetPhase.ready);
    expect(controller.scope?.uid, 'a');
    expect(controller.snapshot?.records.last['name'], 'Private a');
  });
  test('dataset transport uses the token verified for the namespace, never a changed identity token', () async {
    authorization.afterLookup = () => identity.uid = 'b';
    await connect();
    expect(identity.uid, 'b');
    expect(session.identityUid, 'a');
    expect(controller.scope?.uid, 'a');
    expect(api.tokens, ['token-a']);
    expect(controller.snapshot?.records.last['id'], 'pack-a');
  });
  test(
    'another tab revoking the receipt during a scan clears the old dataset',
    () async {
      await connect();
      final incoming = Completer<InitialDataset>();
      api.handler = (_, _) => incoming.future;
      final pending = controller.refresh();
      await waitFor(() => api.calls == 2);
      await store().revoke('project', 'a');
      incoming.complete(
        InitialDataset(records('a', revision: 2), 'revoked-scan'),
      );
      await pending;
      await flush();
      expect(controller.snapshot, isNull);
      expect(controller.scope, isNull);
      expect(session.errorCode, 'scope-changed');
      expect(await store().offlineScope('project', 'a'), isNull);
    },
  );

  test(
    'live role downgrade during a completed scan cannot promote Owner data',
    () async {
      authorization.role = 'owner_admin';
      api.handler = (_, _) async {
        authorization.role = 'collector';
        return InitialDataset([
          ...records('a'),
          {
            'resourceType': 'pack',
            'id': 'foreign-pack',
            'topicId': 'topic',
            'name': 'Other contributor private draft',
            'state': 'hidden',
            'revision': 1,
          },
        ], 'owner-scan');
      };
      await session.validate();
      await waitFor(() => session.errorCode == 'scope-changed');
      await flush();
      expect(api.calls, 1);
      expect(authorization.calls, 2);
      expect(controller.snapshot, isNull);
      expect(controller.scope, isNull);
      expect(await store().offlineScope('project', 'a'), isNull);
    },
  );

  Future<void> ownerConnect() async {
    authorization.role = 'owner_admin';
    api.handler = (_, _) async => InitialDataset([
      {
        'resourceType': 'topic',
        'id': 'topic',
        'name': 'Main Topic',
        'state': 'active',
        'revision': 1,
      },
      {
        'resourceType': 'topic',
        'id': 'other-topic',
        'name': 'Hidden taxonomy',
        'state': 'hidden',
        'revision': 2,
      },
      {
        'resourceType': 'topic',
        'id': 'deleted-topic',
        'name': 'Deleted Topic',
        'state': 'deleted',
        'revision': 3,
      },
      {
        'resourceType': 'topic',
        'id': 'purged-topic',
        'state': 'purged',
        'revision': 4,
      },
      {
        'resourceType': 'pack',
        'id': 'pack-a',
        'topicId': 'topic',
        'name': 'Pack A',
        'state': 'active',
        'revision': 1,
      },
      {
        'resourceType': 'card',
        'id': 'card-a',
        'packId': 'pack-a',
        'name': 'Card A',
        'state': 'active',
        'revision': 1,
        'imageReference': 'opaque',
        'difficulty': 1,
      },
    ], 'owner-resume');
    await connect();
  }

  test('Owner creates and queues Topic locally without changing synced records or making network writes', () async {
    await ownerConnect();
    final recordsBefore = controller.snapshot!.records;
    final calls = api.calls;
    await controller.createTopic('New Topic');
    final draft = controller.snapshot!.drafts.single;
    expect(draft.resourceType, 'topic');
    expect(draft.action, 'create');
    expect(draft.baseRevision, isNull);
    expect(draft.value, {'name': 'New Topic'});
    expect(controller.snapshot!.records, recordsBefore);
    expect(
      controller.topics.singleWhere((t) => t.id == draft.resourceId).revision,
      0,
    );
    expect(
      controller.eligibleTopics.any((t) => t.id == draft.resourceId),
      isFalse,
    );
    await controller.renameTopic(draft.resourceId, 'Renamed new Topic');
    expect(controller.snapshot!.drafts.single.action, 'create');
    expect(controller.snapshot!.drafts.single.resourceId, draft.resourceId);
    await controller.queueDraft(draft.id);
    expect(controller.snapshot!.drafts.single.status, DraftStatus.unsent);
    expect(api.calls, calls);
  });

  test('Owner rename hide soft-delete and restore produce explicit pending actions and preserve relationships', () async {
    await ownerConnect();
    await controller.renameTopic('topic', 'Renamed Main');
    expect(
      controller.topics.singleWhere((t) => t.id == 'topic').name,
      'Renamed Main',
    );
    expect(controller.snapshot!.drafts.single.action, 'update');
    expect(controller.snapshot!.drafts.single.baseRevision, 1);
    await expectLater(
      controller.hideTopic('topic'),
      throwsA(storageFailure('topic-pending-change')),
    );
    await controller.discardDraft(controller.snapshot!.drafts.single.id);
    await controller.hideTopic('topic');
    expect(
      controller.topics.singleWhere((t) => t.id == 'topic').state,
      'hidden',
    );
    expect(controller.eligibleTopics.any((t) => t.id == 'topic'), isTrue);
    await controller.queueDraft(controller.snapshot!.drafts.single.id);
    expect(controller.snapshot!.drafts.single.action, 'hide');
    await controller.discardDraft(controller.snapshot!.drafts.single.id);
    await controller.deleteTopic('topic');
    expect(
      controller.topics.singleWhere((t) => t.id == 'topic').state,
      'deleted',
    );
    expect(controller.eligibleTopics.any((t) => t.id == 'topic'), isFalse);
    expect(
      controller.snapshot!.records.singleWhere(
        (r) => r['id'] == 'pack-a',
      )['topicId'],
      'topic',
    );
    expect(
      controller.snapshot!.records.singleWhere(
        (r) => r['id'] == 'topic',
      )['state'],
      'active',
    );
    await controller.discardDraft(controller.snapshot!.drafts.single.id);
    await controller.restoreTopic('deleted-topic');
    expect(
      controller.topics.singleWhere((t) => t.id == 'deleted-topic').state,
      'hidden',
    );
    expect(
      controller.eligibleTopics.any((t) => t.id == 'deleted-topic'),
      isFalse,
      reason: 'server parent is still deleted',
    );
    await controller.queueDraft(controller.snapshot!.drafts.single.id);
    expect(controller.snapshot!.drafts.single.action, 'restore');
  });

  test(
    'Topic lifecycle refuses purged wrong-state and uncommitted new identities',
    () async {
      await ownerConnect();
      for (final action in [
        () => controller.restoreTopic('purged-topic'),
        () => controller.restoreTopic('topic'),
        () => controller.hideTopic('other-topic'),
        () => controller.renameTopic('deleted-topic', 'No'),
        () => controller.deleteTopic('missing'),
      ]) {
        await expectLater(
          action(),
          throwsA(storageFailure('invalid-topic-state')),
        );
      }
      await controller.createTopic('Pending parent');
      final id = controller.snapshot!.drafts.single.resourceId;
      await expectLater(
        controller.hideTopic(id),
        throwsA(storageFailure('topic-pending-change')),
      );
      await expectLater(
        controller.deleteTopic(id),
        throwsA(storageFailure('topic-pending-change')),
      );
      await expectLater(
        controller.createPackDraft(name: 'Orphan', topicId: id),
        throwsA(storageFailure('topic-not-eligible')),
      );
      expect(controller.snapshot!.drafts.length, 1);
    },
  );

  test('Collector can classify Pack drafts with hidden existing taxonomy but cannot mutate Topics by any entrypoint', () async {
    await connect();
    final before = controller.snapshot!.toJson();
    for (final action in [
      () => controller.createTopic('No'),
      () => controller.renameTopic('topic', 'No'),
      () => controller.hideTopic('topic'),
      () => controller.deleteTopic('topic'),
      () => controller.restoreTopic('topic'),
    ]) {
      await expectLater(action(), throwsA(storageFailure('forbidden')));
    }
    expect(controller.snapshot!.toJson(), before);
    expect(controller.topics.single.pending, isNull);
    expect(controller.eligibleTopics.single.id, 'topic');
    await controller.createPackDraft(
      name: 'Own classified draft',
      topicId: 'topic',
    );
    final pack = controller.snapshot!.drafts.single;
    expect(pack.action, 'create');
    expect(pack.baseRevision, isNull);
    expect(pack.value, {'name': 'Own classified draft', 'topicId': 'topic'});
    await controller.queueDraft(pack.id);
    await controller.updatePackDraft(
      pack.id,
      name: 'Updated local Pack',
      topicId: 'topic',
    );
    expect(controller.snapshot!.drafts.single.status, DraftStatus.draft);
    expect(controller.snapshot!.drafts.single.resourceId, pack.resourceId);
    await expectLater(
      controller.createPackDraft(name: 'No', topicId: 'foreign-or-deleted'),
      throwsA(storageFailure('topic-not-eligible')),
    );
    await expectLater(
      controller.updatePackDraft(
        pack.id,
        name: 'No',
        topicId: 'foreign-or-deleted',
      ),
      throwsA(storageFailure('topic-not-eligible')),
    );
  });

  test('Collector cannot queue or discard an injected Topic draft even if UI is bypassed', () async {
    await connect();
    controller.snapshot = controller.snapshot!.copyWith(
      drafts: [
        LocalDraft(
          id: 'injected',
          resourceType: 'topic',
          resourceId: 'topic',
          baseRevision: 1,
          value: {'name': 'No'},
        ),
      ],
    );
    final before = controller.snapshot!.toJson();
    await expectLater(
      controller.queueDraft('injected'),
      throwsA(storageFailure('forbidden')),
    );
    await expectLater(
      controller.discardDraft('injected'),
      throwsA(storageFailure('forbidden')),
    );
    expect(controller.snapshot!.toJson(), before);
    expect(controller.topics.single.pending, isNull);
  });

  test('Topic delete and dependent local child drafts cannot coexist in either write order', () async {
    await ownerConnect();
    await controller.createPackDraft(name: 'Pending child', topicId: 'topic');
    final before = controller.snapshot!.toJson();
    await expectLater(
      controller.deleteTopic('topic'),
      throwsA(storageFailure('topic-has-pending-children')),
    );
    expect(controller.snapshot!.toJson(), before);
    await controller.discardDraft(controller.snapshot!.drafts.single.id);
    await controller.saveDraft(
      controller.snapshot!.records.singleWhere((r) => r['id'] == 'card-a'),
      name: 'Pending Card',
    );
    await expectLater(
      controller.deleteTopic('topic'),
      throwsA(storageFailure('topic-has-pending-children')),
    );
    await controller.discardDraft(controller.snapshot!.drafts.single.id);
    await controller.deleteTopic('topic');
    final deleting = controller.snapshot!.toJson();
    await expectLater(
      controller.createPackDraft(name: 'Orphan', topicId: 'topic'),
      throwsA(storageFailure('topic-not-eligible')),
    );
    await expectLater(
      controller.saveDraft(
        controller.snapshot!.records.singleWhere((r) => r['id'] == 'pack-a'),
        name: 'Late Pack',
      ),
      throwsA(storageFailure('topic-has-pending-children')),
    );
    expect(controller.snapshot!.toJson(), deleting);
  });

  test('pending Topic and Pack creates survive refresh while absent remotely and reload durably', () async {
    await ownerConnect();
    await controller.createTopic('Pending Topic');
    await controller.createPackDraft(name: 'Pending Pack', topicId: 'topic');
    final ids = controller.snapshot!.drafts.map((d) => d.id).toList();
    await controller.refresh();
    expect(controller.snapshot!.drafts.map((d) => d.id), ids);
    expect(
      controller.snapshot!.drafts.every(
        (d) => d.action == 'create' && d.status == DraftStatus.draft,
      ),
      isTrue,
    );
    final persisted = await store().read(controller.scope!);
    expect(
      persisted!.drafts.map((d) => d.toJson()),
      controller.snapshot!.drafts.map((d) => d.toJson()),
    );
  });

  test('missing parent on refresh marks Pack create conflict instead of leaving a queueable orphan', () async {
    await connect();
    await controller.createPackDraft(name: 'Pending Pack', topicId: 'topic');
    api.handler = (_, _) async => const InitialDataset([], 'removed-parent');
    await controller.refresh();
    expect(controller.snapshot!.drafts.single.status, DraftStatus.conflict);
    await expectLater(
      controller.queueDraft(controller.snapshot!.drafts.single.id),
      throwsA(storageFailure('draft-conflict')),
    );
  });

  test('Topic queue state is retained across revision conflict and writes stop after account detach', () async {
    await ownerConnect();
    await controller.renameTopic('topic', 'Keep local');
    final id = controller.snapshot!.drafts.single.id;
    await controller.queueDraft(id);
    api.handler = (_, _) async => InitialDataset([
      {
        'resourceType': 'topic',
        'id': 'topic',
        'name': 'Remote changed',
        'state': 'active',
        'revision': 2,
      },
    ], 'changed');
    await controller.refresh();
    expect(controller.snapshot!.drafts.single.status, DraftStatus.conflict);
    expect(controller.snapshot!.drafts.single.value['name'], 'Keep local');
    await expectLater(
      controller.queueDraft(id),
      throwsA(storageFailure('draft-conflict')),
    );
    await session.logout();
    await expectLater(
      controller.createTopic('Late'),
      throwsA(storageFailure('storage-closed')),
    );
    expect(controller.snapshot, isNull);
  });
  test('name editing derives parent revision and state from stored record instead of caller data', () async {
    await connect();
    final pack = controller.snapshot!.records.last;
    await controller.saveDraft({
      ...pack,
      'topicId': 'forged-topic',
      'revision': 999,
      'state': 'purged',
    }, name: 'Legitimate rename');
    final draft = controller.snapshot!.drafts.single;
    expect(draft.baseRevision, pack['revision']);
    expect(draft.value['topicId'], pack['topicId']);
    expect(draft.value['state'], pack['state']);
    await controller.queueDraft(draft.id);
    controller.snapshot = controller.snapshot!.copyWith(
      drafts: [
        draft.copyWith(value: {...draft.value, 'topicId': 'foreign'}),
      ],
    );
    await expectLater(
      controller.queueDraft(draft.id),
      throwsA(storageFailure('invalid-draft')),
    );
  });
  test(
    'Topic names reject C1 controls and unpaired surrogate code units',
    () async {
      await ownerConnect();
      for (final name in [
        'Bad\u0085name',
        String.fromCharCodes([0x41, 0xd800]),
      ]) {
        await expectLater(
          controller.createTopic(name),
          throwsA(storageFailure('invalid-draft')),
        );
      }
      expect(controller.snapshot!.drafts, isEmpty);
    },
  );
  test('Collector cache with an injected Topic draft is rejected before rendering or syncing', () async {
    await connect();
    final handle = store();
    final saved = (await handle.read(controller.scope!))!;
    await handle.save(
      saved.copyWith(
        drafts: [
          LocalDraft(
            id: 'injected',
            resourceType: 'topic',
            resourceId: 'topic',
            baseRevision: 1,
            value: {'name': 'Private injected Topic'},
          ),
        ],
      ),
      expectedVersion: saved.version,
    );
    controller.dispose();
    api = _Api();
    controller = createController()..start();
    await waitFor(() => controller.phase == DatasetPhase.error);
    expect(controller.errorCode, 'invalid-dataset');
    expect(controller.snapshot, isNull);
    expect(controller.scope, isNull);
    expect(api.calls, 0);
  });
}
