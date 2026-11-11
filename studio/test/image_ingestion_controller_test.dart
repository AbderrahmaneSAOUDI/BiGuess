import 'dart:async';
import 'dart:convert';

import 'package:biguess_studio/auth/studio_session.dart';
import 'package:biguess_studio/data/card_image.dart';
import 'package:biguess_studio/data/dataset_api.dart';
import 'package:biguess_studio/data/dataset_controller.dart';
import 'package:biguess_studio/data/dataset_store.dart';
import 'package:biguess_studio/data/image_ingestion.dart';
import 'package:biguess_studio/data/studio_dataset.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dataset_controller_test.dart' show records, waitFor, storageFailure;
import 'image_ingestion_test.dart' show preparedUploadImage, uploadReceiptJson;

class _Identity implements StudioIdentity {
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

class _Authorization implements StudioAuthorization {
  String? failure;
  @override
  Future<StudioPrincipal> lookup(String token) async {
    if (failure != null) throw SessionFailure(failure!);
    final uid = token.substring('token-'.length);
    return StudioPrincipal(uid, '$uid@example.test', 'collector');
  }
}

class _DatasetApi implements DatasetApi {
  @override
  Future<InitialDataset> initial(String token, bool Function() current) async =>
      InitialDataset(records(token.substring('token-'.length)), 'resume');
  @override
  void close() {}
}

class _Images implements ImageIngestionApi {
  int calls = 0;
  bool closed = false;
  String? failure;
  Completer<UploadedCardImage>? pending;
  Future<void>? cancellation;
  String? lastPack;
  int? lastRevision;
  CardImage? lastImage;
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
    lastPack = packId;
    lastRevision = revision;
    lastImage = image;
    cancellation = cancelled;
    expect(token, 'token-a');
    if (failure != null) throw DatasetApiFailure(failure!);
    return pending?.future ??
        UploadedCardImage.fromJson(
          uploadReceiptJson(packId: packId, image: image),
        );
  }

  @override
  void close() {
    closed = true;
  }
}

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
    database.snapshots.removeWhere(
      (_, snapshot) =>
          snapshot.scope.project == project && snapshot.scope.uid == uid,
    );
  }

  @override
  void close() {}
}

void main() {
  late _Identity identity;
  late _Authorization authorization;
  late _Images images;
  late _MemoryDatabase database;
  late StudioSession session;
  late DatasetController controller;
  late bool online;
  Future<void> connect() async {
    await session.validate();
    await waitFor(
      () =>
          controller.phase == DatasetPhase.ready && controller.snapshot != null,
    );
  }

  Future<String> draft() async {
    await controller.createCardDraft(
      packId: 'pack-a',
      name: 'Ada',
      difficulty: 2,
      image: preparedUploadImage(),
    );
    return controller.snapshot!.drafts.single.id;
  }

  setUp(() {
    identity = _Identity();
    authorization = _Authorization();
    images = _Images();
    database = _MemoryDatabase();
    online = true;
    session = StudioSession(identity, authorization, online: () => online);
    controller = DatasetController(
      projectId: 'ingestion-tests',
      session: session,
      api: _DatasetApi(),
      storeFactory: () => _MemoryStore(database),
      imageIngestion: images,
    )..start();
  });
  tearDown(() async {
    controller.dispose();
    session.dispose();
    await identity.events.close();
  });

  test('saving and queueing are local; explicit upload stores receipt and retains canonical ID and preview', () async {
    await connect();
    final id = await draft();
    final original = controller.snapshot!.drafts.single;
    await controller.queueDraft(id);
    expect(images.calls, 0);
    await controller.uploadCardImage(id);
    final uploaded = controller.snapshot!.drafts.single;
    expect(images.lastPack, 'pack-a');
    expect(images.lastRevision, 1);
    expect(images.lastImage!.base64, original.localImage!.base64);
    expect(uploaded.resourceId, original.resourceId);
    expect(uploaded.status, DraftStatus.unsent);
    expect(uploaded.localImage!.base64, original.localImage!.base64);
    expect(
      uploaded.value['imageReference'],
      uploaded.uploadedImage!.imageReference,
    );
    expect(
      uploaded.uploadedImage!.matches('pack-a', uploaded.localImage!),
      isTrue,
    );
    expect(
      controller.snapshot!.records.where((r) => r['resourceType'] == 'card'),
      isEmpty,
    );
    expect(
      database
          .snapshots[controller.scope!.namespace]!
          .drafts
          .single
          .uploadedImage!
          .toJson(),
      uploaded.uploadedImage!.toJson(),
    );
  });

  test(
    'image replacement clears the old binding while name edits retain it',
    () async {
      await connect();
      final id = await draft();
      await controller.uploadCardImage(id);
      final receipt = controller.snapshot!.drafts.single.uploadedImage!;
      await controller.updateCardDraft(
        id,
        packId: 'pack-a',
        name: 'New name',
        difficulty: 3,
      );
      expect(
        controller.snapshot!.drafts.single.uploadedImage!.toJson(),
        receipt.toJson(),
      );
      await controller.updateCardDraft(
        id,
        packId: 'pack-a',
        name: 'New name',
        difficulty: 3,
        image: preparedUploadImage(hash: 'c' * 64),
      );
      expect(controller.snapshot!.drafts.single.uploadedImage, isNull);
      expect(
        controller.snapshot!.drafts.single.value['imageReference'],
        isNull,
      );
      expect(
        controller.snapshot!.drafts.single.localImage!.preparation!.sha256,
        'c' * 64,
      );
    },
  );

  test('offline upload is rejected before transport while local image remains editable', () async {
    await connect();
    final id = await draft();
    online = false;
    await session.validate();
    await waitFor(() => controller.phase == DatasetPhase.offline);
    expect(controller.canUploadImages, isFalse);
    await expectLater(
      controller.uploadCardImage(id),
      throwsA(storageFailure('image-upload-unavailable')),
    );
    expect(images.calls, 0);
    expect(controller.snapshot!.drafts.single.localImage, isNotNull);
    await controller.updateCardDraft(
      id,
      packId: 'pack-a',
      name: 'Offline name',
      difficulty: 1,
    );
    expect(controller.snapshot!.drafts.single.value['name'], 'Offline name');
  });

  test('interrupted upload can retry without losing the local image or changing the Card ID', () async {
    await connect();
    final id = await draft();
    final original = controller.snapshot!.drafts.single;
    images.failure = 'image-upload-interrupted';
    await expectLater(
      controller.uploadCardImage(id),
      throwsA(storageFailure('image-upload-interrupted')),
    );
    expect(controller.snapshot!.drafts.single.toJson(), original.toJson());
    expect(controller.uploadingImageDraftId, isNull);
    images.failure = null;
    await controller.uploadCardImage(id);
    expect(images.calls, 2);
    expect(controller.snapshot!.drafts.single.resourceId, original.resourceId);
    expect(controller.snapshot!.drafts.single.uploadedImage, isNotNull);
  });

  test('storage quota failure after server upload retains draft and safely retries the same candidate', () async {
    await connect();
    final id = await draft();
    final original = controller.snapshot!.toJson();
    database.quota = true;
    await expectLater(
      controller.uploadCardImage(id),
      throwsA(storageFailure('quota-exceeded')),
    );
    expect(controller.snapshot!.toJson(), original);
    database.quota = false;
    await controller.uploadCardImage(id);
    expect(images.calls, 2);
    expect(
      images.lastImage!.preparation!.sha256,
      preparedUploadImage().preparation!.sha256,
    );
    expect(controller.snapshot!.drafts.single.uploadedImage, isNotNull);
  });

  test('late prior-account upload is cancelled and cannot attach a receipt to the next account', () async {
    await connect();
    final id = await draft();
    images.pending = Completer<UploadedCardImage>();
    final upload = controller.uploadCardImage(id);
    final assertion = expectLater(upload, throwsA(storageFailure('cancelled')));
    await waitFor(() => images.calls == 1);
    var aborted = false;
    unawaited(images.cancellation!.then((_) => aborted = true));
    await session.logout();
    await session.signIn();
    identity.uid = 'b';
    session.identityUid = 'b';
    await connect();
    images.pending!.complete(UploadedCardImage.fromJson(uploadReceiptJson()));
    await assertion;
    expect(aborted, isTrue);
    expect(controller.scope!.uid, 'b');
    expect(controller.snapshot!.drafts, isEmpty);
  });

  test(
    'authorization denial during upload revokes the private workspace',
    () async {
      await connect();
      final id = await draft();
      images.failure = 'forbidden';
      await expectLater(
        controller.uploadCardImage(id),
        throwsA(storageFailure('forbidden')),
      );
      expect(session.phase, SessionPhase.denied);
      expect(controller.snapshot, isNull);
      expect(controller.scope, isNull);
    },
  );

  test('editing the image during an upload rejects its stale receipt instead of overwriting the replacement', () async {
    await connect();
    final id = await draft();
    images.pending = Completer<UploadedCardImage>();
    final upload = controller.uploadCardImage(id);
    final assertion = expectLater(
      upload,
      throwsA(storageFailure('draft-conflict')),
    );
    await waitFor(() => images.calls == 1);
    await controller.updateCardDraft(
      id,
      packId: 'pack-a',
      name: 'Replacement',
      difficulty: 1,
      image: preparedUploadImage(hash: 'c' * 64),
    );
    images.pending!.complete(UploadedCardImage.fromJson(uploadReceiptJson()));
    await assertion;
    expect(controller.snapshot!.drafts.single.uploadedImage, isNull);
    expect(
      controller.snapshot!.drafts.single.localImage!.preparation!.sha256,
      'c' * 64,
    );
  });
}
