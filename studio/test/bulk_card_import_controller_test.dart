import 'dart:async';
import 'dart:convert';

import 'package:biguess_studio/auth/studio_session.dart';
import 'package:biguess_studio/data/bulk_card_import.dart';
import 'package:biguess_studio/data/card_image.dart';
import 'package:biguess_studio/data/dataset_api.dart';
import 'package:biguess_studio/data/dataset_controller.dart';
import 'package:biguess_studio/data/dataset_store.dart';
import 'package:biguess_studio/data/image_ingestion.dart';
import 'package:biguess_studio/data/studio_dataset.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dataset_controller_test.dart' show records, waitFor;
import 'image_ingestion_test.dart' show preparedUploadImage;

class _MemoryDatabase {
  final snapshots = <String, DatasetSnapshot>{};
  final authorized = <String, DatasetScope>{};
  bool quota = false;
}

class _MemoryStore implements DatasetStore {
  _MemoryStore(this.database);
  final _MemoryDatabase database;
  @override
  Future<void> authorize(DatasetScope scope) async {
    database.authorized[scope.accountKey] = scope;
  }

  @override
  Future<DatasetScope?> offlineScope(String project, String uid) async =>
      database.authorized[jsonEncode([project, uid])];
  @override
  Future<DatasetSnapshot?> read(DatasetScope scope) async =>
      database.snapshots[scope.namespace];
  @override
  Future<DatasetSnapshot> save(
    DatasetSnapshot snapshot, {
    required int expectedVersion,
  }) async {
    if (database.quota) throw const DatasetStorageFailure('quota-exceeded');
    final version = database.snapshots[snapshot.scope.namespace]?.version ?? 0;
    if (version != expectedVersion) {
      throw const DatasetStorageFailure('storage-conflict');
    }
    final saved = DatasetSnapshot.fromJson(
      Map<String, Object?>.from(
        jsonDecode(jsonEncode(snapshot.copyWith(version: version + 1).toJson()))
            as Map,
      ),
    );
    database.snapshots[snapshot.scope.namespace] = saved;
    return saved;
  }

  @override
  Future<void> revoke(String project, String uid) async {
    database.authorized.remove(jsonEncode([project, uid]));
  }

  @override
  void close() {}
}

class _TestIdentity implements StudioIdentity {
  _TestIdentity();
  String? uid = 'a';
  final events = StreamController<String?>.broadcast(sync: true);
  @override
  Stream<String?> get changes => events.stream;
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
    events.add(null);
  }
}

class _TestAuthorization implements StudioAuthorization {
  _TestAuthorization();
  String role = 'collector';
  @override
  Future<StudioPrincipal> lookup(String token) async {
    final uid = token.substring('token-'.length);
    return StudioPrincipal(uid, '$uid@example.test', role);
  }
}

class _TestDatasetApi implements DatasetApi {
  int commitCalls = 0;
  bool failConflict = false;
  final committedBatches = <Map<String, Object?>>[];
  final idempotencyKeys = <String>[];
  final revisions = <int>[];

  @override
  Future<InitialDataset> initial(String token, bool Function() current) async {
    final uid = token.substring('token-'.length);
    return InitialDataset([
      ...records(uid),
      {
        'resourceType': 'card',
        'id': 'card-$uid',
        'packId': 'pack-$uid',
        'name': 'Original Card',
        'imageReference': 'objects/original.png',
        'difficulty': 1,
        'state': 'active',
        'revision': 1,
      },
    ], 'resume');
  }

  @override
  Future<BatchCommitResult> commitBatch(
    String token, {
    required String idempotencyKey,
    required int revision,
    required Map<String, Object?> batch,
    required bool Function() current,
  }) async {
    commitCalls++;
    idempotencyKeys.add(idempotencyKey);
    revisions.add(revision);
    committedBatches.add(batch);
    if (failConflict) throw const DatasetApiFailure('draft-conflict');
    return BatchCommitResult(
      revision: revision + 1,
      committedAt: DateTime.now().toUtc().toIso8601String(),
      actorId: token.split('-').last,
    );
  }

  @override
  void close() {}
}

class _TestImageIngestion implements ImageIngestionApi {
  int calls = 0;
  bool failQuota = false;
  final uploadedHashes = <String>{};

  @override
  Future<UploadedCardImage> upload(
    String token,
    String packId,
    int revision,
    CardImage image,
    bool Function() current, {
    required Future<void> cancelled,
  }) async {
    calls++;
    if (failQuota) throw const DatasetApiFailure('image-quota');
    final sha256 =
        image.preparation?.sha256 ??
        '28e2c5feee64c1c1a0bdc757a79db4a538c71079970c1259e9d3493ff0a93b89';
    uploadedHashes.add(sha256);
    return UploadedCardImage(
      packId: packId,
      imageReference: 'objects/$sha256.png',
      sha256: sha256,
      byteLength: image.bytes.length,
      contentType: 'image/png',
      width: image.preparation?.width ?? 2,
      height: image.preparation?.height ?? 2,
    );
  }

  @override
  void close() {}
}

void main() {
  late _TestIdentity identity;
  late _TestAuthorization authorization;
  late _TestDatasetApi api;
  late _TestImageIngestion images;
  late _MemoryDatabase database;
  late StudioSession session;
  late DatasetController controller;

  setUp(() {
    identity = _TestIdentity();
    authorization = _TestAuthorization();
    api = _TestDatasetApi();
    images = _TestImageIngestion();
    database = _MemoryDatabase();
    session = StudioSession(identity, authorization, online: () => true);
    controller = DatasetController(
      projectId: 'bulk-tests',
      session: session,
      api: api,
      storeFactory: () => _MemoryStore(database),
      imageIngestion: images,
    )..start();
  });

  tearDown(() async {
    controller.dispose();
    session.dispose();
    await identity.events.close();
  });

  Future<void> connect() async {
    await session.validate();
    await waitFor(
      () =>
          controller.phase == DatasetPhase.ready && controller.snapshot != null,
    );
  }

  test('saveBulkCardDrafts saves items to drafts and IndexedDB store for reload survival', () async {
    await connect();
    final img = preparedUploadImage();
    final items = [
      BulkImportItem(
        id: controller.newCardId(),
        sourceFilename: 'image1.png',
        name: 'Card One',
        difficulty: 1,
        image: img,
      ),
      BulkImportItem(
        id: controller.newCardId(),
        sourceFilename: 'image2.png',
        name: 'Card Two',
        difficulty: 2,
        image: img,
      ),
    ];

    await controller.saveBulkCardDrafts(packId: 'pack-a', items: items);

    expect(controller.snapshot!.drafts.length, 2);
    expect(controller.cards.any((c) => c.name == 'Card One'), isTrue);
    expect(controller.cards.any((c) => c.name == 'Card Two'), isTrue);

    // Verify drafts in store
    final stored = await _MemoryStore(database).read(controller.scope!);
    expect(stored!.drafts.length, 2);
  });

  test('importAndCommitBulkCards chunks 120 items into batches of 100 and 20 with revision reconciliation', () async {
    await connect();
    final img = preparedUploadImage();
    final items = List.generate(
      120,
      (i) => BulkImportItem(
        id: controller.newCardId(),
        sourceFilename: 'img_$i.png',
        name: 'Hero $i',
        difficulty: (i % 3) + 1,
        image: img,
      ),
    );

    final progressUpdates = <BulkImportProgress>[];
    final result = await controller.importAndCommitBulkCards(
      packId: 'pack-a',
      items: items,
      onProgress: progressUpdates.add,
    );

    expect(result.committedCount, 120);
    expect(result.batchCount, 2);
    expect(
      result.finalRevision,
      3,
    ); // starts at 1, chunk 1 -> rev 2, chunk 2 -> rev 3

    // Verify 120 image uploads
    expect(images.calls, 120);

    // Verify 2 commit chunks
    expect(api.commitCalls, 2);
    expect(api.revisions, [
      1,
      2,
    ]); // First batch sent with rev 1, second with rev 2!
    expect(
      api.committedBatches[0]['operations'],
      hasLength(100),
    ); // First chunk has 100 items
    expect(
      api.committedBatches[1]['operations'],
      hasLength(20),
    ); // Second chunk has 20 items

    // Unique UUIDv4 idempotency keys
    expect(api.idempotencyKeys.length, 2);
    expect(api.idempotencyKeys[0], isNot(equals(api.idempotencyKeys[1])));
    expect(
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(api.idempotencyKeys[0]),
      isTrue,
    );

    // Check that cards are committed in snapshot
    final packCards = controller.cards.where(
      (c) => c.packId == 'pack-a' && c.name.startsWith('Hero '),
    );
    expect(packCards.length, 120);
    expect(packCards.where((c) => c.revision == 2).length, 100);
    expect(packCards.where((c) => c.revision == 3).length, 20);
    expect(packCards.every((c) => c.state == 'active'), isTrue);
  });

  test(
    'quota failure during image upload stops cleanly without sending commit',
    () async {
      await connect();
      final img = preparedUploadImage();
      final items = [
        BulkImportItem(
          id: controller.newCardId(),
          sourceFilename: 'img.png',
          name: 'Hero',
          difficulty: 1,
          image: img,
        ),
      ];
      images.failQuota = true;

      expect(
        () =>
            controller.importAndCommitBulkCards(packId: 'pack-a', items: items),
        throwsA(
          isA<DatasetStorageFailure>().having(
            (e) => e.code,
            'code',
            'image-quota',
          ),
        ),
      );

      expect(api.commitCalls, 0);
    },
  );

  test(
    'bulkHideCards and bulkUpdateDifficulty work for Collector in owned pack',
    () async {
      await connect();
      // card-a belongs to pack-a
      await controller.bulkUpdateDifficulty(['card-a'], 3);
      final updated = controller.cards.firstWhere((c) => c.id == 'card-a');
      expect(updated.difficulty, 3);
      expect(updated.pending?.action, 'update');

      // Discard draft to test hide
      await controller.discardDraft(updated.pending!.id);

      await controller.bulkHideCards(['card-a']);
      final hidden = controller.cards.firstWhere((c) => c.id == 'card-a');
      expect(hidden.pending?.action, 'hide');
    },
  );

  test(
    'bulkDeleteCards is Owner-only and throws forbidden for Collector',
    () async {
      await connect();
      expect(
        () => controller.bulkDeleteCards(['card-a']),
        throwsA(
          isA<DatasetStorageFailure>().having(
            (e) => e.code,
            'code',
            'forbidden',
          ),
        ),
      );
    },
  );
}
