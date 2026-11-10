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
}
