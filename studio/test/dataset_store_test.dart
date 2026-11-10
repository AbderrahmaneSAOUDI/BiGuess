import 'dart:convert';

import 'package:biguess_studio/data/dataset_store.dart';
import 'package:biguess_studio/data/indexed_db_dataset_store.dart';
import 'package:biguess_studio/data/studio_dataset.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb.dart';

import 'support/dataset_test_factory_stub.dart'
    if (dart.library.js_interop) 'support/dataset_test_factory_web.dart';

const a = DatasetScope('project', 'uid-a', 'collector');
const b = DatasetScope('project', 'uid-b', 'collector');
const owner = DatasetScope('project', 'uid-a', 'owner_admin');
final synced = DateTime.utc(2026, 11, 10);
DatasetSnapshot sample(DatasetScope scope) => DatasetSnapshot(
  scope: scope,
  records: [
    {
      'resourceType': 'topic',
      'id': 'topic',
      'name': 'Taxonomy',
      'state': 'hidden',
      'revision': 1,
    },
    {
      'resourceType': 'pack',
      'id': 'pack-${scope.uid}',
      'topicId': 'topic',
      'name': 'Only ${scope.uid}',
      'state': 'active',
      'revision': 3,
    },
  ],
  drafts: [
    LocalDraft(
      id: 'pending-${scope.uid}',
      resourceType: 'pack',
      resourceId: 'pack-${scope.uid}',
      baseRevision: 3,
      value: {'name': 'Offline edit'},
      status: DraftStatus.unsent,
    ),
  ],
  lastSyncedAt: synced,
  resumeCursor: 'opaque-not-an-auth-token',
);
Matcher failure(String code) =>
    isA<DatasetStorageFailure>().having((e) => e.code, 'code', code);

void main() {
  final factory = datasetTestFactory();
  late String name;
  late List<IndexedDbDatasetStore> handles;
  IndexedDbDatasetStore open({
    void Function()? beforeSaveCommit,
    Duration? timeout,
  }) {
    final store = IndexedDbDatasetStore(
      factory,
      databaseName: name,
      beforeSaveCommit: beforeSaveCommit,
      openTimeout: timeout ?? const Duration(seconds: 10),
    );
    handles.add(store);
    return store;
  }

  setUp(() {
    name = 'studio-dataset-test-${DateTime.now().microsecondsSinceEpoch}';
    handles = [];
  });
  tearDown(() async {
    for (final store in handles) {
      store.close();
    }
    await factory.deleteDatabase(name);
  });

  test(
    'a new connection reopens the complete dataset and durable draft queue',
    () async {
      final first = open();
      expect(await first.offlineScope(a.project, a.uid), isNull);
      await first.authorize(a);
      expect(await first.offlineScope(a.project, a.uid), isNull);
      final written = await first.save(sample(a), expectedVersion: 0);
      expect(written.version, 1);
      first.close();
      final reopened = open();
      expect(
        (await reopened.offlineScope(a.project, a.uid))?.namespace,
        a.namespace,
      );
      final read = (await reopened.read(a))!;
      expect(read.records[1]['name'], 'Only uid-a');
      expect(read.drafts.single.status, DraftStatus.unsent);
      expect(read.drafts.single.value['name'], 'Offline edit');
      expect(read.lastSyncedAt, synced);
      expect(read.resumeCursor, 'opaque-not-an-auth-token');
    },
  );

  test(
    'project, UID and role namespaces never share records or pending drafts',
    () async {
      final store = open();
      await store.authorize(a);
      await store.save(sample(a), expectedVersion: 0);
      await store.authorize(b);
      await store.save(sample(b), expectedVersion: 0);
      expect((await store.read(a))!.records[1]['id'], 'pack-uid-a');
      expect((await store.read(b))!.records[1]['id'], 'pack-uid-b');
      expect(await store.offlineScope('other-project', a.uid), isNull);
      await store.authorize(owner);
      expect(await store.offlineScope(a.project, a.uid), isNull);
      await expectLater(store.read(a), throwsA(failure('storage-revoked')));
      await store.save(sample(owner), expectedVersion: 0);
      expect(
        (await store.offlineScope(a.project, a.uid))?.namespace,
        owner.namespace,
      );
      await store.authorize(a);
      expect((await store.read(a))!.drafts.single.id, 'pending-uid-a');
    },
  );

  test('revocation blocks offline reopening, reads and a delayed save without losing drafts', () async {
    final first = open();
    final second = open();
    await first.authorize(a);
    final saved = await first.save(sample(a), expectedVersion: 0);
    await second.revoke(a.project, a.uid);
    expect(await first.offlineScope(a.project, a.uid), isNull);
    expect(await first.read(a), isNull);
    await expectLater(
      first.save(saved.copyWith(drafts: []), expectedVersion: saved.version),
      throwsA(failure('storage-revoked')),
    );
    await second.authorize(a);
    expect((await first.read(a))!.drafts, hasLength(1));
  });

  test('competing tab writes use a transaction CAS and cannot overwrite pending edits', () async {
    final one = open();
    final two = open();
    await one.authorize(a);
    final saved = await one.save(sample(a), expectedVersion: 0);
    final stale = (await two.read(a))!;
    final newest = await one.save(
      saved.copyWith(
        drafts: [saved.drafts.single.copyWith(status: DraftStatus.conflict)],
      ),
      expectedVersion: saved.version,
    );
    await expectLater(
      two.save(stale.copyWith(drafts: []), expectedVersion: stale.version),
      throwsA(failure('storage-conflict')),
    );
    final actual = (await two.read(a))!;
    expect(actual.version, newest.version);
    expect(actual.drafts.single.status, DraftStatus.conflict);
  });

  test('quota error aborts the real transaction and retry after recovery keeps previous data', () async {
    final good = open();
    await good.authorize(a);
    final saved = await good.save(sample(a), expectedVersion: 0);
    final failing = open(
      beforeSaveCommit: () => throw StateError('QuotaExceededError'),
    );
    await expectLater(
      failing.save(saved.copyWith(records: []), expectedVersion: saved.version),
      throwsA(failure('quota-exceeded')),
    );
    final previous = (await good.read(a))!;
    expect(previous.records, hasLength(2));
    expect(previous.version, saved.version);
    final recovered = await good.save(
      previous.copyWith(
        drafts: [previous.drafts.single.copyWith(status: DraftStatus.draft)],
      ),
      expectedVersion: previous.version,
    );
    expect(recovered.version, 2);
    expect((await good.read(a))!.drafts.single.status, DraftStatus.draft);
  });

  test('v1 snapshots migrate additively and require an online receipt before offline use', () async {
    final legacy = await factory.open(
      name,
      version: 1,
      onUpgradeNeeded: (event) => event.database.createObjectStore('datasets'),
    );
    final tx = legacy.transaction('datasets', idbModeReadWrite);
    final old = sample(a).copyWith(version: 7);
    await tx.objectStore('datasets').put(jsonEncode(old.toJson()), a.namespace);
    await tx.completed;
    legacy.close();
    final upgraded = open();
    expect(await upgraded.offlineScope(a.project, a.uid), isNull);
    await upgraded.authorize(a);
    final recovered = (await upgraded.read(a))!;
    expect(recovered.version, 7);
    expect(recovered.drafts.single.status, DraftStatus.unsent);
    expect(recovered.records, old.records);
  });

  test('future schema versions fail closed without resetting data', () async {
    final future = await factory.open(
      name,
      version: 3,
      onUpgradeNeeded: (event) => event.database.createObjectStore('future'),
    );
    final tx = future.transaction('future', idbModeReadWrite);
    await tx.objectStore('future').put('retained', 'fence');
    await tx.completed;
    future.close();
    await expectLater(open().authorize(a), throwsA(failure('storage-version')));
    final checked = await factory.open(name, version: 3);
    final read = checked.transaction('future', idbModeReadOnly);
    expect(await read.objectStore('future').getObject('fence'), 'retained');
    await read.completed;
    checked.close();
  });

  test('corrupt or cleared-site data cannot become an offline authorization bypass', () async {
    final raw = await factory.open(
      name,
      version: 2,
      onUpgradeNeeded: (event) {
        event.database.createObjectStore('datasets');
        event.database.createObjectStore('accounts');
      },
    );
    final tx = raw.transactionList(['datasets', 'accounts'], idbModeReadWrite);
    await tx.objectStore('accounts').put({
      'scope': a.toJson(),
      'allowed': true,
    }, a.accountKey);
    await tx.objectStore('datasets').put('{"schemaVersion":99}', a.namespace);
    await tx.completed;
    raw.close();
    await Future<void>.delayed(Duration.zero);
    final store = open();
    await expectLater(
      store.offlineScope(a.project, a.uid),
      throwsA(failure('storage-corrupt')),
    );
    store.close();
    await Future<void>.delayed(Duration.zero);
    await factory.deleteDatabase(name);
    expect(await open().offlineScope(a.project, a.uid), isNull);
  });

  test('closing a handle prevents later work after account detach', () async {
    final store = open();
    await store.authorize(a);
    store.close();
    await expectLater(store.read(a), throwsA(failure('storage-closed')));
    await expectLater(
      store.save(sample(a), expectedVersion: 0),
      throwsA(failure('storage-closed')),
    );
  });

  if (kIsWeb) {
    test('a blocked schema upgrade reports recovery instead of resetting another tab', () async {
      final blocked = await factory.open(
        name,
        version: 1,
        onUpgradeNeeded: (event) =>
            event.database.createObjectStore('datasets'),
      );
      final store = open(timeout: const Duration(milliseconds: 50));
      await expectLater(
        store.authorize(a),
        throwsA(failure('storage-blocked')),
      );
      store.close();
      blocked.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final recovered = open();
      await recovered.authorize(a);
      expect(await recovered.read(a), isNull);
    });
  }
}
