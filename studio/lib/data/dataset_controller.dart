import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../auth/studio_session.dart';
import 'dataset_api.dart';
import 'dataset_store.dart';
import 'studio_dataset.dart';
import 'offline_access_policy.dart';

enum DatasetPhase { idle, loading, ready, offline, error, denied }

/// Owns one visible account at a time. Staging never replaces a good snapshot
/// until every page and the IndexedDB transaction have completed successfully.
class DatasetController extends ChangeNotifier {
  DatasetController({
    required this.projectId,
    required this.session,
    required this.api,
    this.storeFactory = createDatasetStore,
  });
  final String projectId;
  final StudioSession session;
  final DatasetApi api;
  final DatasetStore Function() storeFactory;
  DatasetScope? scope;
  DatasetSnapshot? snapshot;
  DatasetPhase phase = DatasetPhase.idle;
  String? errorCode;
  bool get busy => phase == DatasetPhase.loading;
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

  bool _current(int epoch) => !_disposed && epoch == _epoch;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _sessionChanged() {
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
      if (cached != null) _validate(cached.records, target);
      scope = target;
      snapshot = cached;
      if (offline && cached == null) {
        throw const DatasetStorageFailure('offline-unavailable');
      }
      phase = offline ? DatasetPhase.offline : DatasetPhase.ready;
      _notify();
      if (!offline && _autoSyncedNamespace != target.namespace) {
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
    final serial = _syncSerial;
    await session.validate(refresh: true);
    await _handling;
    if (session.phase != SessionPhase.authorized || scope == null || busy) {
      return;
    }
    if (_syncSerial == serial) await _sync(_epoch);
  }

  Future<void> retryStorage() async {
    // Every online retry rechecks live authorization before opening private data.
    await refresh();
  }

  Future<void> _sync(int epoch) async {
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
      final incoming = await api.initial(
        token,
        () => _current(epoch) && session.phase == SessionPhase.authorized,
      );
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
      final prior = snapshot;
      final byId = {
        for (final r in incoming.records)
          jsonEncode([r['resourceType'], r['id']]): r,
      };
      final drafts = (prior?.drafts ?? <LocalDraft>[]).map((draft) {
        final remote = byId[jsonEncode([draft.resourceType, draft.resourceId])];
        return remote == null || remote['revision'] != draft.baseRevision
            ? draft.copyWith(status: DraftStatus.conflict)
            : draft;
      }).toList();
      final next = DatasetSnapshot(
        scope: target,
        records: incoming.records,
        drafts: drafts,
        resumeCursor: incoming.resumeCursor,
        lastSyncedAt: DateTime.now().toUtc(),
        version: prior?.version ?? 0,
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
    final previous = snapshot;
    final store = _store;
    final epoch = _epoch;
    if (previous == null ||
        store == null ||
        !{DatasetPhase.ready, DatasetPhase.offline}.contains(phase)) {
      throw const DatasetStorageFailure('storage-closed');
    }
    try {
      final saved = await store.save(
        previous.copyWith(drafts: drafts),
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
    if (name.trim().isEmpty ||
        name.trim() != name ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
      throw const DatasetStorageFailure('invalid-draft');
    }
    final kind = record['resourceType'];
    if (!{'pack', 'card'}.contains(kind) ||
        !{'active', 'hidden'}.contains(record['state'])) {
      throw const DatasetStorageFailure('invalid-draft');
    }
    final previous = snapshot;
    if (previous == null ||
        !previous.records.any(
          (r) => r['resourceType'] == kind && r['id'] == record['id'],
        )) {
      throw const DatasetStorageFailure('storage-closed');
    }
    final key = jsonEncode([kind, record['id']]);
    final existing = previous.drafts.where((d) => d.id == key).firstOrNull;
    final draft = LocalDraft(
      id: key,
      resourceType: kind! as String,
      resourceId: record['id']! as String,
      baseRevision: existing?.baseRevision ?? record['revision']! as int,
      value: {...record, 'name': name},
      status: existing?.status == DraftStatus.conflict
          ? DraftStatus.conflict
          : DraftStatus.draft,
      publishedRevision: existing?.publishedRevision,
    );
    await _saveDrafts([...previous.drafts.where((d) => d.id != key), draft]);
  }

  Future<void> queueDraft(String draftId) async {
    final drafts = snapshot?.drafts;
    if (drafts == null) throw const DatasetStorageFailure('storage-closed');
    if (drafts.any(
      (d) => d.id == draftId && d.status == DraftStatus.conflict,
    )) {
      throw const DatasetStorageFailure('draft-conflict');
    }
    await _saveDrafts(
      drafts
          .map(
            (d) => d.id == draftId ? d.copyWith(status: DraftStatus.unsent) : d,
          )
          .toList(),
    );
  }

  Future<void> discardDraft(String draftId) async {
    final drafts = snapshot?.drafts;
    if (drafts == null) throw const DatasetStorageFailure('storage-closed');
    await _saveDrafts(drafts.where((d) => d.id != draftId).toList());
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
    _epoch++;
    session.removeListener(_sessionChanged);
    scope = null;
    snapshot = null;
    _store?.close();
    api.close();
    super.dispose();
  }
}
