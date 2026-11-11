import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../auth/studio_session.dart';
import 'dataset_api.dart';
import 'card_image.dart';
import 'card_summary.dart';
import 'dataset_store.dart';
import 'studio_dataset.dart';
import 'offline_access_policy.dart';
import 'topic_taxonomy.dart';
import 'pack_summary.dart';
import 'image_ingestion.dart';
import 'bulk_card_import.dart';
import 'dataset_search.dart';
import 'publication_api.dart';

enum DatasetPhase { idle, loading, ready, offline, error, denied }

/// Owns one visible account at a time. Staging never replaces a good snapshot
/// until every page and the IndexedDB transaction have completed successfully.
class DatasetController extends ChangeNotifier {
  DatasetController({
    required this.projectId,
    required this.session,
    required this.api,
    this.storeFactory = createDatasetStore,
    this.imageIngestion,
    this.publication,
  });
  final String projectId;
  final StudioSession session;
  final DatasetApi api;
  final ImageIngestionApi? imageIngestion;
  final PublicationApi? publication;
  String? uploadingImageDraftId;
  Completer<void>? _imageUploadCancellation;
  bool get canUploadImages =>
      imageIngestion != null &&
      phase == DatasetPhase.ready &&
      session.phase == SessionPhase.authorized;
  final DatasetStore Function() storeFactory;
  DatasetScope? scope;
  DatasetSnapshot? snapshot;
  DatasetPhase phase = DatasetPhase.idle;
  String? errorCode;
  bool _networkBusy = false;
  bool get busy => _networkBusy || phase == DatasetPhase.loading;

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    if (busy || uploadingImageDraftId != null) {
      throw const DatasetStorageFailure('sync-busy');
    }
    _networkBusy = true;
    _notify();
    try {
      return await action();
    } finally {
      _networkBusy = false;
      _notify();
    }
  }

  DatasetStore? _store;
  String? _lastUid;
  int _epoch = 0;
  int _syncSerial = 0;
  String? _autoSyncedNamespace;
  final _offlinePolicy = OfflineAccessPolicy();
  bool _disposed = false;
  bool _started = false;
  Future<void> _handling = Future.value();
  Future<void> _cleanup = Future.value();

  void start() {
    if (_started) return;
    _started = true;
    session.addListener(_sessionChanged);
    _sessionChanged();
  }

  DatasetSearchIndex? _searchIndex;

  DatasetSearchIndex get searchIndex =>
      _searchIndex ??= DatasetSearchIndex.build(this);

  bool _current(int epoch) => !_disposed && epoch == _epoch;
  void _notify() {
    _searchIndex = null;
    if (!_disposed) notifyListeners();
  }

  void _sessionChanged() {
    _searchIndex = null;
    cancelImageUpload();
    final epoch = ++_epoch;
    final oldStore = _store;
    _store = null;
    scope = null;
    snapshot = null;
    errorCode = null;
    phase = DatasetPhase.idle;
    oldStore?.close();
    final uid = session.identityUid ?? _lastUid;
    final revoke =
        session.signedOutByUser ||
        session.phase == SessionPhase.signedOut ||
        session.phase == SessionPhase.denied ||
        {
          'session-expired',
          'user-token-expired',
          'invalid-user-token',
          'user-disabled',
          'scope-changed',
        }.contains(session.errorCode);
    if (uid != null && revoke) {
      _autoSyncedNamespace = null;
      _offlinePolicy.deny(projectId, uid);
      // Serialize invalidation before any subsequent account authorization.
      _cleanup = _cleanup.then((_) async {
        DatasetStore? store;
        try {
          store = storeFactory();
          await store.revoke(projectId, uid);
        } catch (_) {
          /* No cache is displayed on failed revocation writes. */
        } finally {
          store?.close();
        }
      });
    }
    _lastUid = session.identityUid ?? _lastUid;
    _notify();
    if (session.phase == SessionPhase.authorized ||
        session.phase == SessionPhase.offline) {
      phase = DatasetPhase.loading;
      _notify();
      _handling = _attach(epoch);
      unawaited(_handling);
    }
  }

  Future<void> _attach(int epoch) async {
    DatasetStore? store;
    try {
      await _cleanup;
      if (!_current(epoch)) return;
      store = storeFactory();
      _store = store;
      final principal = session.principal;
      DatasetScope? target;
      final offline = session.phase == SessionPhase.offline;
      if (offline) {
        _autoSyncedNamespace = null;
        final uid = session.identityUid;
        if (uid == null || session.signedOutByUser) {
          throw const DatasetStorageFailure('offline-unavailable');
        }
        if (_offlinePolicy.denied(projectId, uid)) {
          throw const DatasetStorageFailure('offline-unavailable');
        }
        target = await store.offlineScope(projectId, uid);
        if (target == null) {
          throw const DatasetStorageFailure('offline-unavailable');
        }
      } else {
        if (principal == null) return;
        target = DatasetScope(projectId, principal.uid, principal.role);
        await store.authorize(target);
        if (_current(epoch)) {
          _offlinePolicy.allow(projectId, target.uid);
        }
      }
      if (!_current(epoch)) return;
      final cached = await store.read(target);
      if (!_current(epoch)) return;
      if (cached != null) {
        _validate(cached.records, target);
        if (target.role == 'collector' &&
            cached.drafts.any(
              (d) =>
                  d.resourceType == 'topic' ||
                  {
                    'softDelete',
                    'restore',
                    'permanentDelete',
                  }.contains(d.action),
            )) {
          throw const DatasetApiFailure('invalid-dataset');
        }
      }
      scope = target;
      snapshot = cached;
      if (offline && cached == null) {
        throw const DatasetStorageFailure('offline-unavailable');
      }
      phase = offline ? DatasetPhase.offline : DatasetPhase.ready;
      _notify();
      if (!offline &&
          cached == null &&
          _autoSyncedNamespace != target.namespace) {
        _autoSyncedNamespace = target.namespace;
        await _sync(epoch);
      }
    } catch (error) {
      if (!_current(epoch)) return;
      scope = null;
      snapshot = null;
      errorCode = _code(error);
      phase = DatasetPhase.error;
      _notify();
    } finally {
      if (!_current(epoch)) store?.close();
    }
  }

  Future<void> refresh() async {
    if (_disposed || busy) return;
    await _exclusive(() async {
      final serial = _syncSerial;
      await session.validate(refresh: true);
      await _handling;
      if (session.phase != SessionPhase.authorized ||
          scope == null ||
          phase == DatasetPhase.loading) {
        return;
      }
      if (_syncSerial == serial) await _sync(_epoch);
    });
  }

  /// A persisted intent is retried verbatim, including after a lost response or
  /// reload. Never rebase an uncertain write onto a freshly fetched revision.
  Future<void> commit() async {
    if (_disposed || busy) return;
    final observed = snapshot;
    await _exclusive(() async {
      await session.validate(refresh: true);
      await _handling;
      if (session.phase != SessionPhase.authorized ||
          scope == null ||
          snapshot == null) {
        return;
      }
      if (observed == null ||
          observed.scope.namespace != scope!.namespace ||
          observed.version != snapshot!.version) {
        errorCode = 'storage-conflict';
        _notify();
        return;
      }
      final epoch = _epoch;
      try {
        while (_current(epoch)) {
          var prior = snapshot!;
          var intent = prior.pendingCommit;
          if (intent == null) {
            final draft = prior.drafts
                .where((d) => d.status == DraftStatus.unsent)
                .firstOrNull;
            if (draft == null) break;
            _validateQueuedDraft(draft);
            if (draft.localImage != null && draft.uploadedImage == null) {
              throw const DatasetStorageFailure('image-upload-required');
            }
            final kind = draft.resourceType == 'card'
                ? 'pack'
                : draft.resourceType;
            final id = draft.resourceType == 'card'
                ? draft.value['packId']
                : draft.resourceId;
            final aggregate = prior.records
                .where((r) => r['resourceType'] == kind && r['id'] == id)
                .firstOrNull;
            final value = draft.resourceType == 'card'
                ? _cardValue(draft.value)
                : draft.resourceType == 'pack'
                ? {
                    'name': draft.value['name'],
                    'topicId': draft.value['topicId'],
                  }
                : {'name': draft.value['name']};
            intent = {
              'key': _uuidV4(),
              'draftId': draft.id,
              'revision': aggregate?['revision'] ?? 0,
              'batch': {
                'protocolVersion': 1,
                'aggregate': {'resourceType': kind, 'id': id},
                'operations': [
                  {
                    'resourceType': draft.resourceType,
                    'id': draft.resourceId,
                    'action': draft.action,
                    if ({'create', 'update'}.contains(draft.action))
                      'value': value,
                  },
                ],
              },
            };
            final saved = await _store!.save(
              prior.copyWith(pendingCommit: intent),
              expectedVersion: prior.version,
            );
            if (!_current(epoch)) return;
            snapshot = saved;
            prior = saved;
          }
          final target = scope!;
          final token = session.tokenFor(target.uid, target.role);
          if (token == null) throw const DatasetApiFailure('session-expired');
          final result = await api.commitBatch(
            token,
            idempotencyKey: intent['key']! as String,
            revision: intent['revision']! as int,
            batch: Map<String, Object?>.from(intent['batch']! as Map),
            current: () =>
                _current(epoch) && session.phase == SessionPhase.authorized,
          );
          if (!_current(epoch)) return;
          // Promotion and queue acknowledgement share one storage transaction.
          // Failed refresh keeps the intent so the next Commit replays the key.
          await _sync(
            epoch,
            acknowledged: intent['draftId']! as String,
            committedAt: DateTime.parse(result.committedAt),
          );
          if (!_current(epoch) || errorCode != null) break;
        }
      } catch (error) {
        if (!_current(epoch)) return;
        final code = _code(error);
        if ({
          'forbidden',
          'session-expired',
          'storage-revoked',
        }.contains(code)) {
          session.rejectAuthorization(
            code == 'storage-revoked' ? 'scope-changed' : code,
          );
          return;
        }
        if ({'draft-conflict', 'idempotency-conflict'}.contains(code)) {
          final prior = snapshot!;
          final id = prior.pendingCommit?['draftId'];
          try {
            final saved = await _store!.save(
              prior.copyWith(
                clearPendingCommit: true,
                drafts: prior.drafts
                    .map(
                      (d) => d.id == id
                          ? d.copyWith(status: DraftStatus.conflict)
                          : d,
                    )
                    .toList(),
              ),
              expectedVersion: prior.version,
            );
            if (!_current(epoch)) return;
            snapshot = saved;
          } catch (storageError) {
            if (!_current(epoch)) return;
            errorCode = _code(storageError);
            _notify();
            return;
          }
        }
        errorCode = code;
        _notify();
      }
    });
  }

  Future<void> retryStorage() async {
    // Every online retry rechecks live authorization before opening private data.
    await refresh();
  }

  Future<void> _sync(
    int epoch, {
    String? acknowledged,
    DateTime? committedAt,
  }) async {
    final target = scope;
    final store = _store;
    if (target == null ||
        store == null ||
        session.phase != SessionPhase.authorized) {
      return;
    }
    _syncSerial++;
    phase = DatasetPhase.loading;
    errorCode = null;
    _notify();
    try {
      final token = session.tokenFor(target.uid, target.role);
      if (!_current(epoch)) return;
      if (token == null) throw const DatasetApiFailure('session-expired');
      final prior = snapshot;
      bool active() =>
          _current(epoch) && session.phase == SessionPhase.authorized;
      final incoming =
          api is IncrementalDatasetApi && prior?.resumeCursor != null
          ? await (api as IncrementalDatasetApi).changes(
              token,
              prior!.records,
              prior.resumeCursor!,
              active,
              owner: target.role == 'owner_admin',
            )
          : await api.initial(token, active);
      if (!_current(epoch)) return;
      // The allowlist can change between /session and the first dataset page.
      // Recheck before promoting data or displaying retained Owner drafts.
      final verified = await session.authorization.lookup(token);
      if (!_current(epoch)) return;
      if (verified.uid != target.uid || verified.role != target.role) {
        session.rejectAuthorization('scope-changed');
        return;
      }
      _validate(incoming.records, target);
      final byId = {
        for (final r in incoming.records)
          jsonEncode([r['resourceType'], r['id']]): r,
      };
      final drafts = (prior?.drafts ?? <LocalDraft>[])
          .where((d) => d.id != acknowledged)
          .map((draft) {
            final remote =
                byId[jsonEncode([draft.resourceType, draft.resourceId])];
            final parent =
                {'pack', 'card'}.contains(draft.resourceType) &&
                    draft.action == 'create'
                ? incoming.records
                      .where(
                        (r) =>
                            r['resourceType'] ==
                                (draft.resourceType == 'pack'
                                    ? 'topic'
                                    : 'pack') &&
                            r['id'] ==
                                draft.value[draft.resourceType == 'pack'
                                    ? 'topicId'
                                    : 'packId'],
                      )
                      .firstOrNull
                : null;
            final conflict = draft.action == 'create'
                ? remote != null ||
                      ({'pack', 'card'}.contains(draft.resourceType) &&
                          (parent == null ||
                              !{'active', 'hidden'}.contains(parent['state'])))
                : remote == null || remote['revision'] != draft.baseRevision;
            return conflict
                ? draft.copyWith(status: DraftStatus.conflict)
                : draft;
          })
          .toList();
      final next = DatasetSnapshot(
        scope: target,
        records: incoming.records,
        drafts: drafts,
        resumeCursor: incoming.resumeCursor,
        lastSyncedAt: DateTime.now().toUtc(),
        version: prior?.version ?? 0,
        pendingCommit: acknowledged == null ? prior?.pendingCommit : null,
        lastCommittedAt: committedAt ?? prior?.lastCommittedAt,
      );
      final saved = await store.save(
        next,
        expectedVersion: prior?.version ?? 0,
      );
      if (!_current(epoch)) return;
      snapshot = saved;
      phase = DatasetPhase.ready;
    } catch (error) {
      if (!_current(epoch)) return;
      final code = _code(error);
      if (code == 'storage-revoked') {
        session.rejectAuthorization('scope-changed');
        return;
      }
      if (code == 'forbidden' || code == 'session-expired') {
        session.rejectAuthorization(code);
        return;
      }
      errorCode = code;
      phase = snapshot == null ? DatasetPhase.error : DatasetPhase.ready;
    }
    _notify();
  }

  void _validate(List<Map<String, Object?>> records, DatasetScope target) {
    for (final record in records) {
      validateDatasetRecord(record);
      if (target.role == 'collector' &&
          (!{'active', 'hidden'}.contains(record['state']) ||
              record.containsKey('createdByUid') ||
              record.containsKey('createdAt'))) {
        throw const DatasetApiFailure('invalid-dataset');
      }
    }
    validateDatasetRelationships(records);
  }

  Future<void> _saveDrafts(List<LocalDraft> drafts) async {
    if (snapshot?.pendingCommit != null) {
      throw const DatasetStorageFailure('commit-pending');
    }
    final previous = snapshot;
    final store = _store;
    final epoch = _epoch;
    if (previous == null ||
        store == null ||
        !{DatasetPhase.ready, DatasetPhase.offline}.contains(phase)) {
      throw const DatasetStorageFailure('storage-closed');
    }
    final candidate = previous.copyWith(drafts: drafts);
    if (drafts.any(
      (d) =>
          d.resourceType == 'topic' &&
          d.action == 'softDelete' &&
          _hasPendingChildren(candidate, d.resourceId),
    )) {
      throw const DatasetStorageFailure('topic-has-pending-children');
    }
    if (drafts.any(
      (d) =>
          d.resourceType == 'pack' &&
          {'softDelete', 'permanentDelete'}.contains(d.action) &&
          _hasPackDraftChildren(candidate, d.resourceId),
    )) {
      throw const DatasetStorageFailure('pack-has-pending-children');
    }
    try {
      final saved = await store.save(
        candidate,
        expectedVersion: previous.version,
      );
      if (!_current(epoch)) throw const DatasetStorageFailure('storage-closed');
      snapshot = saved;
      errorCode = null;
      _notify();
    } catch (error) {
      if (_current(epoch)) {
        errorCode = _code(error);
        if (errorCode == 'storage-revoked') {
          session.rejectAuthorization('scope-changed');
        }
        _notify();
      }
      rethrow;
    }
  }

  Future<void> saveDraft(
    Map<String, Object?> record, {
    required String name,
  }) async {
    _name(name);
    if (record['resourceType'] == 'pack') {
      final stored = _workingSnapshot().records
          .where((r) => r['resourceType'] == 'pack' && r['id'] == record['id'])
          .firstOrNull;
      if (stored == null) throw const DatasetStorageFailure('storage-closed');
      return updatePack(
        stored['id']! as String,
        name: name,
        topicId: stored['topicId']! as String,
        expectedRevision: record['revision']! as int,
      );
    }
    if (record['resourceType'] == 'card') {
      final stored = _workingSnapshot().records
          .where((r) => r['resourceType'] == 'card' && r['id'] == record['id'])
          .firstOrNull;
      if (stored == null) throw const DatasetStorageFailure('storage-closed');
      return updateCard(
        stored['id']! as String,
        expectedRevision: record['revision']! as int,
        name: name,
        difficulty:
            _workingSnapshot().drafts
                    .where(
                      (d) =>
                          d.resourceType == 'card' &&
                          d.resourceId == stored['id'],
                    )
                    .firstOrNull
                    ?.value['difficulty']
                as int? ??
            stored['difficulty']! as int,
      );
    }
    throw const DatasetStorageFailure('invalid-draft');
  }

  /// Owner working topics include explicit pending changes; Collector taxonomy
  /// is always the minimal nondeleted server projection, without local Topic ops.
  List<TopicTaxonomy> get topics {
    final current = snapshot;
    if (current == null || scope == null) return const [];
    final owner = scope!.role == 'owner_admin';
    final pending = owner
        ? {
            for (final d in current.drafts.where(
              (d) => d.resourceType == 'topic',
            ))
              d.resourceId: d,
          }
        : <String, LocalDraft>{};
    final result = <TopicTaxonomy>[];
    for (final record in current.records.where(
      (r) => r['resourceType'] == 'topic',
    )) {
      if (!owner && !{'active', 'hidden'}.contains(record['state'])) continue;
      final id = record['id']! as String;
      final draft = pending.remove(id);
      final apply = draft != null && draft.status != DraftStatus.conflict;
      final state = apply
          ? switch (draft.action) {
              'hide' || 'restore' => 'hidden',
              'softDelete' => 'deleted',
              _ => record['state']! as String,
            }
          : record['state']! as String;
      result.add(
        TopicTaxonomy(
          id: id,
          name: apply
              ? draft.value['name'] as String? ??
                    record['name'] as String? ??
                    id
              : record['name'] as String? ?? id,
          state: state,
          revision: record['revision']! as int,
          pending: draft,
        ),
      );
    }
    for (final draft in pending.values.where((d) => d.action == 'create')) {
      result.add(
        TopicTaxonomy(
          id: draft.resourceId,
          name: draft.value['name']! as String,
          state: 'active',
          revision: 0,
          pending: draft,
        ),
      );
    }
    result.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()) != 0
          ? a.name.toLowerCase().compareTo(b.name.toLowerCase())
          : a.id.compareTo(b.id),
    );
    return List.unmodifiable(result);
  }

  List<TopicTaxonomy> get eligibleTopics =>
      List.unmodifiable(topics.where((t) => t.eligible));

  DatasetSnapshot _workingSnapshot({bool owner = false}) {
    final current = snapshot;
    if (current == null ||
        scope == null ||
        current.scope.namespace != scope!.namespace ||
        !{DatasetPhase.ready, DatasetPhase.offline}.contains(phase)) {
      throw const DatasetStorageFailure('storage-closed');
    }
    if (owner && scope!.role != 'owner_admin') {
      throw const DatasetStorageFailure('forbidden');
    }
    return current;
  }

  String _name(String value) {
    if (value.isEmpty ||
        value.trim() != value ||
        value.runes.any(
          (rune) =>
              rune <= 0x1f ||
              rune >= 0x7f && rune <= 0x9f ||
              rune >= 0xd800 && rune <= 0xdfff,
        )) {
      throw const DatasetStorageFailure('invalid-draft');
    }
    return value;
  }

  String _newId(String kind) {
    final random = Random.secure();
    return 'studio-$kind-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  }

  String newCardId() => _newId('card');

  String _uuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

  Future<void> createTopic(String name) async {
    final current = _workingSnapshot(owner: true);
    final id = _newId('topic');
    await _saveDrafts([
      ...current.drafts,
      LocalDraft(
        id: jsonEncode(['topic', id]),
        resourceType: 'topic',
        resourceId: id,
        action: 'create',
        value: {'name': _name(name)},
      ),
    ]);
  }

  Future<void> renameTopic(
    String id,
    String name, {
    int? expectedRevision,
  }) async {
    final current = _workingSnapshot(owner: true);
    final existing = current.drafts
        .where((d) => d.resourceType == 'topic' && d.resourceId == id)
        .firstOrNull;
    if (existing?.status == DraftStatus.conflict) {
      throw const DatasetStorageFailure('draft-conflict');
    }
    if (existing != null && !{'create', 'update'}.contains(existing.action)) {
      throw const DatasetStorageFailure('topic-pending-change');
    }
    final record = current.records
        .where((r) => r['resourceType'] == 'topic' && r['id'] == id)
        .firstOrNull;
    if (expectedRevision != null &&
        (record?['revision'] ?? 0) != expectedRevision) {
      throw const DatasetStorageFailure('draft-conflict');
    }
    if (record == null && existing?.action != 'create' ||
        record != null && !{'active', 'hidden'}.contains(record['state'])) {
      throw const DatasetStorageFailure('invalid-topic-state');
    }
    final draft =
        existing?.copyWith(
          value: {'name': _name(name)},
          status: DraftStatus.draft,
        ) ??
        LocalDraft(
          id: jsonEncode(['topic', id]),
          resourceType: 'topic',
          resourceId: id,
          action: 'update',
          baseRevision: record!['revision']! as int,
          value: {'name': _name(name)},
        );
    await _saveDrafts([
      ...current.drafts.where((d) => d.id != draft.id),
      draft,
    ]);
  }

  Future<void> hideTopic(String id, {int? expectedRevision}) =>
      _topicAction(id, 'hide', expectedRevision: expectedRevision);
  Future<void> deleteTopic(String id, {int? expectedRevision}) =>
      _topicAction(id, 'softDelete', expectedRevision: expectedRevision);
  Future<void> restoreTopic(String id, {int? expectedRevision}) =>
      _topicAction(id, 'restore', expectedRevision: expectedRevision);

  bool _hasPendingChildren(DatasetSnapshot current, String topicId) {
    final packs = current.records
        .where((r) => r['resourceType'] == 'pack' && r['topicId'] == topicId)
        .map((r) => r['id'])
        .toSet();
    return current.drafts.any(
      (d) => d.resourceType == 'pack'
          ? d.value['topicId'] == topicId || packs.contains(d.resourceId)
          : d.resourceType == 'card' &&
                (packs.contains(d.value['packId']) ||
                    current.records.any(
                      (r) =>
                          r['resourceType'] == 'card' &&
                          r['id'] == d.resourceId &&
                          packs.contains(r['packId']),
                    )),
    );
  }

  Future<void> _topicAction(
    String id,
    String action, {
    int? expectedRevision,
  }) async {
    final current = _workingSnapshot(owner: true);
    if (current.drafts.any(
      (d) => d.resourceType == 'topic' && d.resourceId == id,
    )) {
      throw const DatasetStorageFailure('topic-pending-change');
    }
    final record = current.records
        .where((r) => r['resourceType'] == 'topic' && r['id'] == id)
        .firstOrNull;
    if (expectedRevision != null && record?['revision'] != expectedRevision) {
      throw const DatasetStorageFailure('draft-conflict');
    }
    if (record == null ||
        (action == 'hide'
            ? record['state'] != 'active'
            : action == 'restore'
            ? record['state'] != 'deleted'
            : !{'active', 'hidden'}.contains(record['state']))) {
      throw const DatasetStorageFailure('invalid-topic-state');
    }
    if (action == 'softDelete' && _hasPendingChildren(current, id)) {
      throw const DatasetStorageFailure('topic-has-pending-children');
    }
    await _saveDrafts([
      ...current.drafts,
      LocalDraft(
        id: jsonEncode(['topic', id]),
        resourceType: 'topic',
        resourceId: id,
        action: action,
        baseRevision: record['revision']! as int,
        value: {'name': record['name']! as String},
      ),
    ]);
  }

  List<PackSummary> get packs {
    final current = snapshot;
    if (current == null || scope == null) return const [];
    final pending = {
      for (final d in current.drafts.where((d) => d.resourceType == 'pack'))
        d.resourceId: d,
    };
    final result = <PackSummary>[];
    final workingCards = cards;
    for (final record in current.records.where(
      (r) => r['resourceType'] == 'pack',
    )) {
      if (scope!.role == 'collector' &&
          !{'active', 'hidden'}.contains(record['state'])) {
        continue;
      }
      final id = record['id']! as String;
      final draft = pending.remove(id);
      final apply = draft != null && draft.status != DraftStatus.conflict;
      final state = apply
          ? switch (draft.action) {
              'hide' || 'restore' => 'hidden',
              'softDelete' => 'deleted',
              'permanentDelete' => 'purged',
              _ => record['state']! as String,
            }
          : record['state']! as String;
      final cardCount = workingCards
          .where(
            (card) =>
                card.packId == id &&
                card.revision > 0 &&
                card.state == 'active' &&
                (card.imageReference ?? '').isNotEmpty &&
                card.name.trim().isNotEmpty &&
                card.localImage == null &&
                card.pending?.status != DraftStatus.conflict,
          )
          .length;
      result.add(
        PackSummary(
          id: id,
          name: apply
              ? draft.value['name'] as String? ??
                    record['name'] as String? ??
                    id
              : record['name'] as String? ?? id,
          topicId: record['topicId']! as String,
          state: state,
          revision: record['revision']! as int,
          pending: draft,
          createdByUid: record['createdByUid'] as String?,
          eligibleCardCount: cardCount,
          parentEligible: eligibleTopics.any((t) => t.id == record['topicId']),
        ),
      );
    }
    for (final draft in pending.values.where((d) => d.action == 'create')) {
      result.add(
        PackSummary(
          id: draft.resourceId,
          name: draft.value['name']! as String,
          topicId: draft.value['topicId']! as String,
          state: 'active',
          revision: 0,
          pending: draft,
          eligibleCardCount: 0,
        ),
      );
    }
    result.sort((a, b) {
      final order = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return order == 0 ? a.id.compareTo(b.id) : order;
    });
    return List.unmodifiable(result);
  }

  Future<void> updatePack(
    String id, {
    required String name,
    required String topicId,
    int? expectedRevision,
  }) async {
    final current = _workingSnapshot();
    final record = current.records
        .where((r) => r['resourceType'] == 'pack' && r['id'] == id)
        .firstOrNull;
    if (record == null || !{'active', 'hidden'}.contains(record['state'])) {
      throw const DatasetStorageFailure('invalid-pack-state');
    }
    if (expectedRevision != null && record['revision'] != expectedRevision) {
      throw const DatasetStorageFailure('draft-conflict');
    }
    if (record['topicId'] != topicId) {
      throw const DatasetStorageFailure('pack-topic-immutable');
    }
    if (!eligibleTopics.any((t) => t.id == topicId)) {
      throw const DatasetStorageFailure('topic-not-eligible');
    }
    final existing = current.drafts
        .where((d) => d.resourceType == 'pack' && d.resourceId == id)
        .firstOrNull;
    if (existing?.status == DraftStatus.conflict ||
        existing != null && existing.baseRevision != record['revision']) {
      throw const DatasetStorageFailure('draft-conflict');
    }
    if (existing != null && existing.action != 'update') {
      throw const DatasetStorageFailure('pack-pending-change');
    }
    final draft = LocalDraft(
      id: jsonEncode(['pack', id]),
      resourceType: 'pack',
      resourceId: id,
      baseRevision: existing?.baseRevision ?? record['revision']! as int,
      value: {'name': _name(name), 'topicId': topicId},
    );
    await _saveDrafts([
      ...current.drafts.where((d) => d.id != draft.id),
      draft,
    ]);
  }

  Future<void> hidePack(String id, {int? expectedRevision}) =>
      _packAction(id, 'hide', expectedRevision: expectedRevision);
  Future<void> deletePack(String id, {int? expectedRevision}) =>
      _packAction(id, 'softDelete', expectedRevision: expectedRevision);
  Future<void> restorePack(String id, {int? expectedRevision}) =>
      _packAction(id, 'restore', expectedRevision: expectedRevision);
  Future<void> purgePack(String id, {int? expectedRevision}) =>
      _packAction(id, 'permanentDelete', expectedRevision: expectedRevision);

  bool _hasPackDraftChildren(DatasetSnapshot current, String id) =>
      current.drafts.any(
        (d) =>
            d.resourceType == 'card' &&
            (d.value['packId'] == id ||
                current.records.any(
                  (r) =>
                      r['resourceType'] == 'card' &&
                      r['id'] == d.resourceId &&
                      r['packId'] == id,
                )),
      );

  void _validatePackOperation(LocalDraft draft) {
    final current = _workingSnapshot(
      owner: {
        'softDelete',
        'restore',
        'permanentDelete',
      }.contains(draft.action),
    );
    final record = current.records
        .where(
          (r) => r['resourceType'] == 'pack' && r['id'] == draft.resourceId,
        )
        .firstOrNull;
    if (!{
      'create',
      'update',
      'hide',
      'softDelete',
      'restore',
      'permanentDelete',
    }.contains(draft.action)) {
      throw const DatasetStorageFailure('invalid-draft');
    }
    // T28 name drafts retained a complete synced record. Accept only matching
    // readonly metadata on updates, then normalize the queued operation below.
    final legacyMetadata = draft.value.keys.where(
      (key) => !{'name', 'topicId'}.contains(key),
    );
    final validMetadata =
        legacyMetadata.isEmpty ||
        draft.action == 'update' &&
            record != null &&
            legacyMetadata.every(
              (key) =>
                  {
                    'resourceType',
                    'id',
                    'state',
                    'revision',
                    'createdByUid',
                    'createdAt',
                  }.contains(key) &&
                  record.containsKey(key) &&
                  record[key] == draft.value[key],
            );
    if (!validMetadata ||
        draft.value['name'] is! String ||
        draft.value['topicId'] is! String) {
      throw const DatasetStorageFailure('invalid-draft');
    }
    _name(draft.value['name']! as String);
    if (draft.action == 'create' ||
        draft.action == 'update' ||
        draft.action == 'hide' ||
        draft.action == 'restore') {
      if (!eligibleTopics.any((t) => t.id == draft.value['topicId'])) {
        throw const DatasetStorageFailure('topic-not-eligible');
      }
    }
    if (draft.action == 'create') return;
    if (record == null ||
        record['state'] == 'purged' ||
        ({'restore', 'permanentDelete'}.contains(draft.action)
            ? record['state'] != 'deleted'
            : !{'active', 'hidden'}.contains(record['state'])) ||
        draft.action == 'hide' && record['state'] != 'active') {
      throw const DatasetStorageFailure('invalid-pack-state');
    }
    if (record['topicId'] != draft.value['topicId']) {
      throw const DatasetStorageFailure('pack-topic-immutable');
    }
    if ({'softDelete', 'permanentDelete'}.contains(draft.action) &&
        _hasPackDraftChildren(current, draft.resourceId)) {
      throw const DatasetStorageFailure('pack-has-pending-children');
    }
    if (draft.action == 'permanentDelete' &&
        current.records.any(
          (r) =>
              r['resourceType'] == 'card' &&
              r['packId'] == draft.resourceId &&
              r['state'] != 'purged',
        )) {
      throw const DatasetStorageFailure('pack-has-children');
    }
  }

  Future<void> _packAction(
    String id,
    String action, {
    int? expectedRevision,
  }) async {
    final current = _workingSnapshot(owner: action != 'hide');
    if (current.drafts.any(
      (d) => d.resourceType == 'pack' && d.resourceId == id,
    )) {
      throw const DatasetStorageFailure('pack-pending-change');
    }
    final record = current.records
        .where((r) => r['resourceType'] == 'pack' && r['id'] == id)
        .firstOrNull;
    if (record == null) throw const DatasetStorageFailure('invalid-pack-state');
    if (expectedRevision != null && record['revision'] != expectedRevision) {
      throw const DatasetStorageFailure('draft-conflict');
    }
    final draft = LocalDraft(
      id: jsonEncode(['pack', id]),
      resourceType: 'pack',
      resourceId: id,
      action: action,
      baseRevision: record['revision']! as int,
      value: {
        'name': record['name'] as String? ?? id,
        'topicId': record['topicId']! as String,
      },
    );
    _validatePackOperation(draft);
    await _saveDrafts([...current.drafts, draft]);
  }

  Future<void> createPackDraft({
    required String name,
    required String topicId,
  }) async {
    final current = _workingSnapshot();
    if (!eligibleTopics.any((t) => t.id == topicId)) {
      throw const DatasetStorageFailure('topic-not-eligible');
    }
    final id = _newId('pack');
    await _saveDrafts([
      ...current.drafts,
      LocalDraft(
        id: jsonEncode(['pack', id]),
        resourceType: 'pack',
        resourceId: id,
        action: 'create',
        value: {'name': _name(name), 'topicId': topicId},
      ),
    ]);
  }

  Future<void> updatePackDraft(
    String draftId, {
    required String name,
    required String topicId,
  }) async {
    final current = _workingSnapshot();
    final draft = current.drafts.where((d) => d.id == draftId).firstOrNull;
    if (draft == null ||
        draft.resourceType != 'pack' ||
        draft.action != 'create' ||
        draft.baseRevision != null ||
        current.records.any(
          (r) => r['resourceType'] == 'pack' && r['id'] == draft.resourceId,
        )) {
      throw const DatasetStorageFailure('invalid-draft');
    }
    if (draft.status == DraftStatus.conflict) {
      throw const DatasetStorageFailure('draft-conflict');
    }
    if (!eligibleTopics.any((t) => t.id == topicId)) {
      throw const DatasetStorageFailure('topic-not-eligible');
    }
    await _saveDrafts(
      current.drafts
          .map(
            (d) => d.id == draftId
                ? d.copyWith(
                    value: {'name': _name(name), 'topicId': topicId},
                    status: DraftStatus.draft,
                  )
                : d,
          )
          .toList(),
    );
  }

  List<PackSummary> get eligibleCardPacks => List.unmodifiable(
    packs.where(
      (pack) =>
          pack.revision > 0 &&
          pack.parentEligible &&
          {'active', 'hidden'}.contains(pack.state) &&
          pack.pending?.status != DraftStatus.conflict &&
          !{
            'softDelete',
            'restore',
            'permanentDelete',
          }.contains(pack.pending?.action),
    ),
  );

  List<CardSummary> get cards {
    final current = snapshot;
    if (current == null || scope == null) return const [];
    final pending = {
      for (final draft in current.drafts.where((d) => d.resourceType == 'card'))
        draft.resourceId: draft,
    };
    final result = <CardSummary>[];
    for (final record in current.records.where(
      (r) => r['resourceType'] == 'card',
    )) {
      if (scope!.role == 'collector' &&
          !{'active', 'hidden'}.contains(record['state'])) {
        continue;
      }
      final id = record['id']! as String;
      final draft = pending.remove(id);
      final apply = draft != null && draft.status != DraftStatus.conflict;
      final value = apply ? draft.value : record;
      result.add(
        CardSummary(
          id: id,
          name: value['name'] as String? ?? record['name'] as String? ?? id,
          imageReference: value['imageReference'] as String?,
          difficulty: value['difficulty'] as int? ?? 1,
          packId: record['packId']! as String,
          state: apply
              ? switch (draft.action) {
                  'hide' || 'restore' => 'hidden',
                  'softDelete' => 'deleted',
                  'permanentDelete' => 'purged',
                  _ => record['state']! as String,
                }
              : record['state']! as String,
          revision: record['revision']! as int,
          pending: draft,
          createdByUid: record['createdByUid'] as String?,
        ),
      );
    }
    for (final draft in pending.values.where((d) => d.action == 'create')) {
      result.add(
        CardSummary(
          id: draft.resourceId,
          name: draft.value['name']! as String,
          imageReference: draft.value['imageReference'] as String?,
          difficulty: draft.value['difficulty']! as int,
          packId: draft.value['packId']! as String,
          state: 'active',
          revision: 0,
          pending: draft,
        ),
      );
    }
    result.sort((a, b) {
      final order = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return order == 0 ? a.id.compareTo(b.id) : order;
    });
    return List.unmodifiable(result);
  }

  Map<String, Object?> _cardValue(
    Map<String, Object?> source, {
    String? name,
    int? difficulty,
    bool replaceImage = false,
  }) => {
    'name': name ?? source['name'],
    'imageReference': replaceImage ? null : source['imageReference'],
    'difficulty': difficulty ?? source['difficulty'],
    'packId': source['packId'],
  };

  void _validateCardOperation(LocalDraft draft) {
    final current = _workingSnapshot(
      owner: {
        'softDelete',
        'restore',
        'permanentDelete',
      }.contains(draft.action),
    );
    final record = current.records
        .where(
          (r) => r['resourceType'] == 'card' && r['id'] == draft.resourceId,
        )
        .firstOrNull;
    if (!{
          'create',
          'update',
          'hide',
          'softDelete',
          'restore',
          'permanentDelete',
        }.contains(draft.action) ||
        draft.id != jsonEncode(['card', draft.resourceId])) {
      throw const DatasetStorageFailure('invalid-draft');
    }
    final metadata = draft.value.keys.where(
      (key) =>
          !{'name', 'imageReference', 'difficulty', 'packId'}.contains(key),
    );
    if (metadata.isNotEmpty &&
        !(draft.action == 'update' &&
            record != null &&
            metadata.every(
              (key) =>
                  {
                    'resourceType',
                    'id',
                    'state',
                    'revision',
                    'createdByUid',
                    'createdAt',
                  }.contains(key) &&
                  record.containsKey(key) &&
                  record[key] == draft.value[key],
            ))) {
      throw const DatasetStorageFailure('invalid-draft');
    }
    final value = draft.value;
    if (value['name'] is! String ||
        value['difficulty'] is! int ||
        ![1, 2, 3].contains(value['difficulty']) ||
        value['packId'] is! String) {
      throw const DatasetStorageFailure('invalid-card');
    }
    _name(value['name']! as String);
    if (draft.localImage != null) {
      if (!{'create', 'update'}.contains(draft.action) ||
          (draft.uploadedImage == null
              ? value['imageReference'] != null
              : !draft.uploadedImage!.matches(
                      value['packId']! as String,
                      draft.localImage!,
                    ) ||
                    value['imageReference'] !=
                        draft.uploadedImage!.imageReference)) {
        throw const DatasetStorageFailure('invalid-card-image');
      }
    } else if (value['imageReference'] is! String ||
        (value['imageReference']! as String).isEmpty) {
      throw const DatasetStorageFailure('invalid-card-image');
    }
    if ({'create', 'update', 'hide', 'restore'}.contains(draft.action) &&
        !eligibleCardPacks.any((pack) => pack.id == value['packId'])) {
      throw const DatasetStorageFailure('pack-not-eligible');
    }
    if (draft.action == 'create') {
      if (record != null ||
          draft.baseRevision != null ||
          draft.localImage == null) {
        throw const DatasetStorageFailure('invalid-draft');
      }
      return;
    }
    if (record == null ||
        record['revision'] != draft.baseRevision ||
        draft.status == DraftStatus.conflict) {
      throw const DatasetStorageFailure('draft-conflict');
    }
    if (record['packId'] != value['packId']) {
      throw const DatasetStorageFailure('card-pack-immutable');
    }
    if (draft.localImage == null &&
        value['imageReference'] != record['imageReference']) {
      throw const DatasetStorageFailure('invalid-card-image');
    }
    if (!{'update'}.contains(draft.action) &&
        _cardValue(record).entries
            .any((entry) => value[entry.key] != entry.value)) {
      throw const DatasetStorageFailure('invalid-draft');
    }
    if (record['state'] == 'purged' ||
        ({'restore', 'permanentDelete'}.contains(draft.action)
            ? record['state'] != 'deleted'
            : !{'active', 'hidden'}.contains(record['state'])) ||
        draft.action == 'hide' && record['state'] != 'active') {
      throw const DatasetStorageFailure('invalid-card-state');
    }
  }

  Future<void> createCardDraft({
    required String packId,
    required String name,
    required int difficulty,
    CardImage? image,
  }) async {
    final current = _workingSnapshot();
    final id = _newId('card');
    final draft = LocalDraft(
      id: jsonEncode(['card', id]),
      resourceType: 'card',
      resourceId: id,
      action: 'create',
      value: {
        'name': _name(name),
        'imageReference': null,
        'difficulty': difficulty,
        'packId': packId,
      },
      localImage: image,
    );
    _validateCardOperation(draft);
    await _saveDrafts([...current.drafts, draft]);
  }

  Future<void> updateCard(
    String id, {
    required String name,
    required int difficulty,
    CardImage? image,
    int? expectedRevision,
  }) async {
    final current = _workingSnapshot();
    final record = current.records
        .where((r) => r['resourceType'] == 'card' && r['id'] == id)
        .firstOrNull;
    if (record == null) throw const DatasetStorageFailure('invalid-card-state');
    if (expectedRevision != null && record['revision'] != expectedRevision) {
      throw const DatasetStorageFailure('draft-conflict');
    }
    final existing = current.drafts
        .where((d) => d.resourceType == 'card' && d.resourceId == id)
        .firstOrNull;
    if (existing?.status == DraftStatus.conflict ||
        existing != null && existing.baseRevision != record['revision']) {
      throw const DatasetStorageFailure('draft-conflict');
    }
    if (existing != null && existing.action != 'update') {
      throw const DatasetStorageFailure('card-pending-change');
    }
    final draft = LocalDraft(
      id: jsonEncode(['card', id]),
      resourceType: 'card',
      resourceId: id,
      baseRevision: existing?.baseRevision ?? record['revision']! as int,
      value: _cardValue(
        existing?.value ?? record,
        name: _name(name),
        difficulty: difficulty,
        replaceImage: image != null,
      ),
      localImage: image ?? existing?.localImage,
      uploadedImage: image == null ? existing?.uploadedImage : null,
    );
    _validateCardOperation(draft);
    await _saveDrafts([
      ...current.drafts.where((d) => d.id != draft.id),
      draft,
    ]);
  }

  Future<void> updateCardDraft(
    String draftId, {
    required String packId,
    required String name,
    required int difficulty,
    CardImage? image,
  }) async {
    final current = _workingSnapshot();
    final existing = current.drafts.where((d) => d.id == draftId).firstOrNull;
    if (existing == null ||
        existing.resourceType != 'card' ||
        existing.action != 'create') {
      throw const DatasetStorageFailure('invalid-draft');
    }
    if (existing.status == DraftStatus.conflict) {
      throw const DatasetStorageFailure('draft-conflict');
    }
    if (existing.value['packId'] != packId) {
      throw const DatasetStorageFailure('card-pack-immutable');
    }
    final draft = existing.copyWith(
      value: _cardValue(
        existing.value,
        name: _name(name),
        difficulty: difficulty,
        replaceImage: image != null,
      ),
      localImage: image,
      clearUploadedImage: image != null,
      status: DraftStatus.draft,
    );
    _validateCardOperation(draft);
    await _saveDrafts([
      ...current.drafts.where((d) => d.id != draft.id),
      draft,
    ]);
  }

  Future<void> hideCard(String id, {int? expectedRevision}) =>
      _cardAction(id, 'hide', expectedRevision: expectedRevision);
  Future<void> deleteCard(String id, {int? expectedRevision}) =>
      _cardAction(id, 'softDelete', expectedRevision: expectedRevision);
  Future<void> restoreCard(String id, {int? expectedRevision}) =>
      _cardAction(id, 'restore', expectedRevision: expectedRevision);
  Future<void> purgeCard(String id, {int? expectedRevision}) =>
      _cardAction(id, 'permanentDelete', expectedRevision: expectedRevision);

  void cancelImageUpload() {
    final cancellation = _imageUploadCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    _imageUploadCancellation = null;
    uploadingImageDraftId = null;
    _notify();
  }

  /// Explicit image-only upload. Card mutation remains a separate queued intent.
  Future<void> uploadCardImage(String draftId) =>
      _exclusive(() => _uploadCardImage(draftId));

  Future<void> _uploadCardImage(String draftId) async {
    if (!canUploadImages || uploadingImageDraftId != null) {
      throw const DatasetStorageFailure('image-upload-unavailable');
    }
    final current = _workingSnapshot();
    final draft = current.drafts.where((d) => d.id == draftId).firstOrNull;
    if (draft == null) throw const DatasetStorageFailure('invalid-draft');
    _validateCardOperation(draft);
    final image = draft.localImage;
    if (image?.preparation == null) {
      throw const DatasetStorageFailure('image-not-prepared');
    }
    final packId = draft.value['packId']! as String;
    final pack = current.records
        .where((r) => r['resourceType'] == 'pack' && r['id'] == packId)
        .firstOrNull;
    if (pack == null) throw const DatasetStorageFailure('pack-not-eligible');
    final target = scope!;
    final epoch = _epoch;
    final token = session.tokenFor(target.uid, target.role);
    if (token == null) {
      throw const DatasetStorageFailure('image-upload-unavailable');
    }
    final cancellation = Completer<void>();
    _imageUploadCancellation = cancellation;
    uploadingImageDraftId = draftId;
    _notify();
    bool active() =>
        _current(epoch) &&
        identical(_imageUploadCancellation, cancellation) &&
        !cancellation.isCompleted &&
        canUploadImages;
    try {
      final principal = await session.authorization.lookup(token);
      if (!active()) throw const DatasetApiFailure('cancelled');
      if (principal.uid != target.uid || principal.role != target.role) {
        session.rejectAuthorization('scope-changed');
        throw const DatasetApiFailure('cancelled');
      }
      final receipt = await imageIngestion!.upload(
        token,
        packId,
        pack['revision']! as int,
        image!,
        active,
        cancelled: cancellation.future,
      );
      if (!active()) throw const DatasetApiFailure('cancelled');
      final latest = _workingSnapshot();
      final same = latest.drafts.where((d) => d.id == draftId).firstOrNull;
      if (same == null ||
          same.localImage == null ||
          !receipt.matches(packId, same.localImage!)) {
        throw const DatasetStorageFailure('draft-conflict');
      }
      final updated = same.copyWith(
        uploadedImage: receipt,
        value: {...same.value, 'imageReference': receipt.imageReference},
      );
      _validateCardOperation(updated);
      await _saveDrafts(
        latest.drafts.map((d) => d.id == draftId ? updated : d).toList(),
      );
    } catch (error) {
      final code = _code(error);
      if (active() && {'session-expired', 'forbidden'}.contains(code)) {
        session.rejectAuthorization(code);
      }
      throw DatasetStorageFailure(code);
    } finally {
      if (identical(_imageUploadCancellation, cancellation)) {
        cancelImageUpload();
      }
    }
  }

  /// Every review/action rechecks the live account. Pending browser edits cannot
  /// be mistaken for the committed revision being approved or distributed.
  Future<PublicationReview> reviewPublication(
    String resourceType,
    String id, {
    String? action,
    PublicationReview? expected,
    String? evidence,
  }) => _exclusive(
    () => _reviewPublication(
      resourceType,
      id,
      action: action,
      expected: expected,
      evidence: evidence,
    ),
  );

  Future<PublicationReview> _reviewPublication(
    String resourceType,
    String id, {
    String? action,
    PublicationReview? expected,
    String? evidence,
  }) async {
    final current = _workingSnapshot(owner: resourceType == 'topic');
    if (publication == null ||
        phase != DatasetPhase.ready ||
        session.phase != SessionPhase.authorized) {
      throw const DatasetStorageFailure('publication-offline');
    }
    if (!{'topic', 'pack'}.contains(resourceType)) {
      throw const DatasetStorageFailure('invalid-publication-action');
    }
    final record = current.records
        .where((r) => r['resourceType'] == resourceType && r['id'] == id)
        .firstOrNull;
    if (record == null || !{'active', 'hidden'}.contains(record['state'])) {
      throw const DatasetStorageFailure('publication-unavailable');
    }
    bool pending(DatasetSnapshot value) => value.drafts.any((draft) {
      if (draft.resourceType == resourceType && draft.resourceId == id) {
        return true;
      }
      final stored = value.records
          .where(
            (r) =>
                r['resourceType'] == draft.resourceType &&
                r['id'] == draft.resourceId,
          )
          .firstOrNull;
      final packId = draft.resourceType == 'pack'
          ? draft.resourceId
          : draft.value['packId'] ?? stored?['packId'];
      if (resourceType == 'pack') return packId == id;
      if (draft.value['topicId'] == id || stored?['topicId'] == id) return true;
      return value.records.any(
        (r) =>
            r['resourceType'] == 'pack' &&
            r['id'] == packId &&
            r['topicId'] == id,
      );
    });
    if (pending(current)) {
      throw const DatasetStorageFailure('publication-pending-changes');
    }
    final target = scope!;
    final epoch = _epoch;
    final token = session.tokenFor(target.uid, target.role);
    if (token == null) throw const DatasetStorageFailure('publication-offline');
    bool active() =>
        _current(epoch) &&
        phase == DatasetPhase.ready &&
        session.phase == SessionPhase.authorized &&
        snapshot != null &&
        !pending(snapshot!);
    try {
      final principal = await session.authorization.lookup(token);
      if (!active()) throw const DatasetApiFailure('cancelled');
      if (principal.uid != target.uid || principal.role != target.role) {
        session.rejectAuthorization('scope-changed');
        throw const DatasetApiFailure('cancelled');
      }
      final result = await publication!.review(
        token,
        resourceType,
        id,
        active,
        action: action,
        expected: expected,
        evidence: evidence,
      );
      if (!active()) throw const DatasetApiFailure('cancelled');
      return result;
    } catch (error) {
      final code = _code(error);
      if (active() && {'session-expired', 'forbidden'}.contains(code)) {
        session.rejectAuthorization(code);
      }
      throw DatasetStorageFailure(code);
    }
  }

  Future<void> saveBulkCardDrafts({
    required String packId,
    required List<BulkImportItem> items,
  }) async {
    final current = _workingSnapshot();
    if (!eligibleCardPacks.any((p) => p.id == packId)) {
      throw const DatasetStorageFailure('pack-not-eligible');
    }
    final drafts = <LocalDraft>[];
    for (final item in items) {
      if (!item.isValid) continue;
      final draft = LocalDraft(
        id: jsonEncode(['card', item.id]),
        resourceType: 'card',
        resourceId: item.id,
        action: 'create',
        value: {
          'name': _name(item.name),
          'imageReference': item.uploadedImage?.imageReference,
          'difficulty': item.difficulty,
          'packId': packId,
        },
        localImage: item.image,
        uploadedImage: item.uploadedImage,
      );
      _validateCardOperation(draft);
      drafts.add(draft);
    }
    if (drafts.isEmpty) return;
    final draftIds = drafts.map((d) => d.id).toSet();
    final retained = current.drafts
        .where((d) => !draftIds.contains(d.id))
        .toList();
    await _saveDrafts([...retained, ...drafts]);
  }

  Future<BulkImportResult> importAndCommitBulkCards({
    required String packId,
    required List<BulkImportItem> items,
    void Function(BulkImportProgress)? onProgress,
    Future<void>? cancelled,
  }) => _exclusive(
    () => _importAndCommitBulkCards(
      packId: packId,
      items: items,
      onProgress: onProgress,
      cancelled: cancelled,
    ),
  );

  Future<BulkImportResult> _importAndCommitBulkCards({
    required String packId,
    required List<BulkImportItem> items,
    void Function(BulkImportProgress)? onProgress,
    Future<void>? cancelled,
  }) async {
    final validItems = items.where((item) => item.isValid).toList();
    if (validItems.isEmpty) {
      throw const DatasetStorageFailure('invalid-card');
    }
    final current = _workingSnapshot();
    if (!eligibleCardPacks.any((p) => p.id == packId)) {
      throw const DatasetStorageFailure('pack-not-eligible');
    }
    final packRecord = current.records
        .where((r) => r['resourceType'] == 'pack' && r['id'] == packId)
        .firstOrNull;
    if (packRecord == null) {
      throw const DatasetStorageFailure('pack-not-eligible');
    }
    final target = scope!;
    final epoch = _epoch;
    final token = session.tokenFor(target.uid, target.role);
    if (token == null) {
      throw const DatasetStorageFailure('image-upload-unavailable');
    }
    bool isCancelled = false;
    unawaited(cancelled?.then((_) => isCancelled = true));
    bool active() => _current(epoch) && !isCancelled && canUploadImages;

    int currentRevision = packRecord['revision']! as int;

    // Stage 1: Upload images
    for (var i = 0; i < validItems.length; i++) {
      if (!active()) throw const DatasetApiFailure('cancelled');
      final item = validItems[i];
      if (item.uploadedImage == null) {
        onProgress?.call(
          BulkImportProgress(
            stage: 'uploading',
            current: i + 1,
            total: validItems.length,
            detail: item.name,
          ),
        );
        final abortCompleter = Completer<void>();
        unawaited(
          cancelled?.then((_) {
            if (!abortCompleter.isCompleted) abortCompleter.complete();
          }),
        );
        try {
          final receipt = await imageIngestion!.upload(
            token,
            packId,
            currentRevision,
            item.image,
            active,
            cancelled: abortCompleter.future,
          );
          item.uploadedImage = receipt;
        } catch (error) {
          final code = _code(error);
          if (active() && {'session-expired', 'forbidden'}.contains(code)) {
            session.rejectAuthorization(code);
          }
          throw DatasetStorageFailure(code);
        }
      }
    }

    // Stage 2: Chunk into batches of up to 100 operations and commit
    const maxOpsPerBatch = 100;
    final chunks = <List<BulkImportItem>>[];
    var currentChunk = <BulkImportItem>[];
    for (final item in validItems) {
      currentChunk.add(item);
      if (currentChunk.length >= maxOpsPerBatch) {
        chunks.add(currentChunk);
        currentChunk = [];
      }
    }
    if (currentChunk.isNotEmpty) {
      chunks.add(currentChunk);
    }

    var batchCount = 0;
    for (var i = 0; i < chunks.length; i++) {
      if (!active()) throw const DatasetApiFailure('cancelled');
      final chunk = chunks[i];
      onProgress?.call(
        BulkImportProgress(
          stage: 'committing',
          current: i + 1,
          total: chunks.length,
        ),
      );

      final idempotencyKey = _uuidV4();
      final batch = {
        'protocolVersion': 1,
        'aggregate': {'resourceType': 'pack', 'id': packId},
        'operations': [
          for (final item in chunk)
            {
              'resourceType': 'card',
              'id': item.id,
              'action': 'create',
              'value': {
                'name': _name(item.name),
                'packId': packId,
                'imageReference': item.uploadedImage!.imageReference,
                'difficulty': item.difficulty,
              },
            },
        ],
      };

      try {
        final result = await api.commitBatch(
          token,
          idempotencyKey: idempotencyKey,
          revision: currentRevision,
          batch: batch,
          current: active,
        );

        currentRevision = result.revision;
        batchCount++;

        // Update local snapshot with newly committed cards and updated pack revision
        final latest = _workingSnapshot();
        final updatedRecords = latest.records.map((r) {
          if (r['resourceType'] == 'pack' && r['id'] == packId) {
            final updated = Map<String, Object?>.from(r);
            updated['revision'] = currentRevision;
            return Map<String, Object?>.unmodifiable(updated);
          }
          return r;
        }).toList();

        for (final item in chunk) {
          updatedRecords.add(
            Map<String, Object?>.unmodifiable({
              'resourceType': 'card',
              'id': item.id,
              'name': _name(item.name),
              'packId': packId,
              'imageReference': item.uploadedImage!.imageReference,
              'difficulty': item.difficulty,
              'state': 'active',
              'revision': currentRevision,
              if (target.role == 'owner_admin') ...{
                'createdByUid': result.actorId,
                'createdAt': result.committedAt,
              },
            }),
          );
        }

        // Remove any drafts for these committed cards
        final chunkIds = chunk.map((item) => item.id).toSet();
        final remainingDrafts = latest.drafts
            .where(
              (d) =>
                  !(d.resourceType == 'card' &&
                      chunkIds.contains(d.resourceId)),
            )
            .toList();

        final updatedSnapshot = latest.copyWith(
          records: updatedRecords,
          drafts: remainingDrafts,
        );

        final saved = await _store?.save(
          updatedSnapshot,
          expectedVersion: latest.version,
        );
        if (!_current(epoch)) {
          throw const DatasetApiFailure('cancelled');
        }
        snapshot = saved ?? updatedSnapshot;
        _notify();
      } catch (error) {
        final code = _code(error);
        if (active() && {'session-expired', 'forbidden'}.contains(code)) {
          session.rejectAuthorization(code);
        }
        throw DatasetStorageFailure(code);
      }
    }

    return BulkImportResult(
      committedCount: validItems.length,
      batchCount: batchCount,
      finalRevision: currentRevision,
    );
  }

  Future<void> bulkHideCards(List<String> cardIds) async {
    if (cardIds.isEmpty) return;
    final current = _workingSnapshot();
    final newDrafts = <LocalDraft>[];
    for (final id in cardIds) {
      if (current.drafts.any(
        (d) => d.resourceType == 'card' && d.resourceId == id,
      )) {
        throw const DatasetStorageFailure('card-pending-change');
      }
      final record = current.records
          .where((r) => r['resourceType'] == 'card' && r['id'] == id)
          .firstOrNull;
      if (record == null || record['state'] != 'active') {
        throw const DatasetStorageFailure('invalid-card-state');
      }
      final draft = LocalDraft(
        id: jsonEncode(['card', id]),
        resourceType: 'card',
        resourceId: id,
        action: 'hide',
        baseRevision: record['revision']! as int,
        value: _cardValue(record),
      );
      _validateCardOperation(draft);
      newDrafts.add(draft);
    }
    await _saveDrafts([...current.drafts, ...newDrafts]);
  }

  Future<void> bulkUpdateDifficulty(
    List<String> cardIds,
    int newDifficulty,
  ) async {
    if (cardIds.isEmpty) return;
    if (![1, 2, 3].contains(newDifficulty)) {
      throw const DatasetStorageFailure('invalid-card');
    }
    final current = _workingSnapshot();
    final newDrafts = <LocalDraft>[];
    final existingDraftIds = <String>{};
    for (final id in cardIds) {
      final record = current.records
          .where((r) => r['resourceType'] == 'card' && r['id'] == id)
          .firstOrNull;
      if (record == null) {
        throw const DatasetStorageFailure('invalid-card-state');
      }
      final existing = current.drafts
          .where((d) => d.resourceType == 'card' && d.resourceId == id)
          .firstOrNull;
      if (existing != null) {
        if (existing.action != 'update' ||
            existing.status == DraftStatus.conflict) {
          throw const DatasetStorageFailure('card-pending-change');
        }
        existingDraftIds.add(existing.id);
      }
      final draft = LocalDraft(
        id: jsonEncode(['card', id]),
        resourceType: 'card',
        resourceId: id,
        baseRevision: existing?.baseRevision ?? record['revision']! as int,
        value: _cardValue(existing?.value ?? record, difficulty: newDifficulty),
        localImage: existing?.localImage,
        uploadedImage: existing?.uploadedImage,
      );
      _validateCardOperation(draft);
      newDrafts.add(draft);
    }
    final retainedDrafts = current.drafts
        .where((d) => !existingDraftIds.contains(d.id))
        .toList();
    await _saveDrafts([...retainedDrafts, ...newDrafts]);
  }

  Future<void> bulkDeleteCards(List<String> cardIds) async {
    if (cardIds.isEmpty) return;
    final current = _workingSnapshot(owner: true);
    final newDrafts = <LocalDraft>[];
    for (final id in cardIds) {
      if (current.drafts.any(
        (d) => d.resourceType == 'card' && d.resourceId == id,
      )) {
        throw const DatasetStorageFailure('card-pending-change');
      }
      final record = current.records
          .where((r) => r['resourceType'] == 'card' && r['id'] == id)
          .firstOrNull;
      if (record == null) {
        throw const DatasetStorageFailure('invalid-card-state');
      }
      final draft = LocalDraft(
        id: jsonEncode(['card', id]),
        resourceType: 'card',
        resourceId: id,
        action: 'softDelete',
        baseRevision: record['revision']! as int,
        value: _cardValue(record),
      );
      _validateCardOperation(draft);
      newDrafts.add(draft);
    }
    await _saveDrafts([...current.drafts, ...newDrafts]);
  }

  Future<void> _cardAction(
    String id,
    String action, {
    int? expectedRevision,
  }) async {
    final current = _workingSnapshot(owner: action != 'hide');
    if (current.drafts.any(
      (d) => d.resourceType == 'card' && d.resourceId == id,
    )) {
      throw const DatasetStorageFailure('card-pending-change');
    }
    final record = current.records
        .where((r) => r['resourceType'] == 'card' && r['id'] == id)
        .firstOrNull;
    if (record == null) throw const DatasetStorageFailure('invalid-card-state');
    if (expectedRevision != null && record['revision'] != expectedRevision) {
      throw const DatasetStorageFailure('draft-conflict');
    }
    final draft = LocalDraft(
      id: jsonEncode(['card', id]),
      resourceType: 'card',
      resourceId: id,
      action: action,
      baseRevision: record['revision']! as int,
      value: _cardValue(record),
    );
    _validateCardOperation(draft);
    await _saveDrafts([...current.drafts, draft]);
  }

  void _validateQueuedDraft(LocalDraft draft) {
    final current = _workingSnapshot(owner: draft.resourceType == 'topic');
    final record = current.records
        .where(
          (r) =>
              r['resourceType'] == draft.resourceType &&
              r['id'] == draft.resourceId,
        )
        .firstOrNull;
    if (draft.status == DraftStatus.conflict ||
        (draft.action == 'create'
            ? record != null || draft.baseRevision != null
            : record == null || record['revision'] != draft.baseRevision)) {
      throw const DatasetStorageFailure('draft-conflict');
    }
    if (draft.action == 'update' &&
        record != null &&
        (draft.resourceType == 'pack' &&
                draft.value['topicId'] != record['topicId'] ||
            draft.resourceType == 'card' &&
                draft.value['packId'] != record['packId'])) {
      throw const DatasetStorageFailure('invalid-draft');
    }
    if (draft.resourceType == 'topic') {
      if (draft.value.keys.length != 1 ||
          !draft.value.containsKey('name') ||
          draft.value['name'] is! String) {
        throw const DatasetStorageFailure('invalid-draft');
      }
      _name(draft.value['name']! as String);
      if (draft.action == 'hide' && record?['state'] != 'active' ||
          draft.action == 'restore' && record?['state'] != 'deleted' ||
          {'update', 'softDelete'}.contains(draft.action) &&
              !{'active', 'hidden'}.contains(record?['state'])) {
        throw const DatasetStorageFailure('invalid-topic-state');
      }
      if (!{
        'create',
        'update',
        'hide',
        'softDelete',
        'restore',
      }.contains(draft.action)) {
        throw const DatasetStorageFailure('invalid-draft');
      }
      if (draft.action == 'softDelete' &&
          _hasPendingChildren(current, draft.resourceId)) {
        throw const DatasetStorageFailure('topic-has-pending-children');
      }
    } else if (draft.resourceType == 'pack') {
      _validatePackOperation(draft);
    } else if (draft.resourceType == 'card') {
      _validateCardOperation(draft);
    }
  }

  Future<void> queueDraft(String draftId) async {
    final current = _workingSnapshot();
    final draft = current.drafts.where((d) => d.id == draftId).firstOrNull;
    if (draft == null) throw const DatasetStorageFailure('invalid-draft');
    _validateQueuedDraft(draft);
    await _saveDrafts(
      current.drafts
          .map(
            (d) => d.id == draftId
                ? d.copyWith(
                    status: DraftStatus.unsent,
                    value: d.resourceType == 'pack'
                        ? {
                            'name': d.value['name'],
                            'topicId': d.value['topicId'],
                          }
                        : d.resourceType == 'card'
                        ? _cardValue(d.value)
                        : null,
                  )
                : d,
          )
          .toList(),
    );
  }

  Future<void> discardDraft(String draftId) async {
    final current = _workingSnapshot();
    final draft = current.drafts.where((d) => d.id == draftId).firstOrNull;
    if (draft == null) throw const DatasetStorageFailure('invalid-draft');
    _workingSnapshot(
      owner:
          draft.resourceType == 'topic' ||
          {'softDelete', 'restore', 'permanentDelete'}.contains(draft.action),
    );
    await _saveDrafts(current.drafts.where((d) => d.id != draftId).toList());
  }

  String _code(Object error) => switch (error) {
    DatasetStorageFailure(:final code) => code,
    DatasetApiFailure(:final code) => code,
    SessionFailure(:final code) => code,
    FormatException() || TypeError() => 'invalid-dataset',
    _ => 'sync-unavailable',
  };

  @override
  void dispose() {
    _disposed = true;
    cancelImageUpload();
    _epoch++;
    session.removeListener(_sessionChanged);
    scope = null;
    snapshot = null;
    _store?.close();
    api.close();
    imageIngestion?.close();
    publication?.close();
    super.dispose();
  }
}
