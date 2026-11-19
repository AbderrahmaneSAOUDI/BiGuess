import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/download/pack_download_repository.dart';
import '../data/local/local_content_runtime.dart';
import '../data/updates/pack_update_repository.dart';
import '../domain/models/pack.dart';
import 'catalog_controller.dart';
import 'content_transfer_gate.dart';
import 'gameplay_network_gate.dart';
import 'pack_download_controller.dart';
import 'topic_pack_providers.dart';

final installedDownloadPacksProvider = Provider<List<Pack>>((ref) {
  if (!(ref.watch(localContentRuntimeProvider)?.usesSqlite ?? false)) {
    return const [];
  }
  final content = ref.watch(contentRepositoryProvider);
  return List.unmodifiable([
    for (final topic in content.getTopics())
      for (final pack in content.getPacksForTopic(topic.id))
        if (content.getInstalledCardsForPack(pack.id) != null) pack,
  ]);
});

final packUpdateRepositoryProvider = Provider<PackUpdateRepository?>((ref) {
  if (ref.watch(gameplayNetworkBlockedProvider)) return null;
  final base = ref.watch(publicCatalogBaseUriProvider);
  final store = ref.watch(localContentRuntimeProvider)?.store;
  if (base == null || store == null) return null;
  final repository = HttpPackUpdateRepository(
    base: base,
    store: store,
    pinnedKeys: ref.watch(packDownloadKeysProvider),
  );
  ref.onDispose(repository.close);
  return repository;
});

class PackUpdateBrowseState {
  const PackUpdateBrowseState({
    this.statuses = const {},
    this.checkedAt,
    this.updatedAt,
    this.busy = false,
    this.packId,
    this.progress,
    this.error,
    this.action,
  });
  final Map<String, PackUpdateStatus> statuses;
  final DateTime? checkedAt, updatedAt;
  final bool busy;
  final String? packId, error, action;
  final PackDownloadProgress? progress;
}

/// Inert until a Home management button is pressed. Statuses describe the last
/// explicit check; navigation, rebuilds and restarts never check or install.
class PackUpdateController extends Notifier<PackUpdateBrowseState> {
  bool _alive = true;
  PackDownloadCancellation? _cancellation;
  Future<void>? _pending;
  @override
  PackUpdateBrowseState build() {
    _alive = true;
    ref.onDispose(() {
      _alive = false;
      _cancellation?.cancel();
    });
    return const PackUpdateBrowseState();
  }

  Future<void> check() => _run(null, (repository) async {
    final results = await repository!.check(cancellation: _cancellation);
    if (!_alive) return;
    _safeBoundary();
    final deleted = results
        .where((s) => s.state == PackUpdateAvailability.deleted)
        .toList();
    if (deleted.isNotEmpty) {
      final origin = ref.read(publicCatalogBaseUriProvider)?.origin;
      if (origin == null ||
          deleted.any(
            (s) => s.tombstone == null || s.tombstone!.sourceOrigin != origin,
          )) {
        throw const PackDownloadFailure('corrupt');
      }
      final runtime = ref.read(localContentRuntimeProvider);
      if (runtime?.store == null) throw const PackDownloadFailure('storage');
      await runtime!.store!.applyTombstones(
        deleted.map((s) => s.tombstone!),
        expectedRevisions: {
          for (final s in deleted) s.packId: s.installedRevision,
        },
        checkCancelled: _safeBoundary,
      );
      await _refreshManagement(runtime);
    }
    if (!_alive) return;
    state = PackUpdateBrowseState(
      statuses: Map.unmodifiable({
        for (final result in results) result.packId: result,
      }),
      checkedAt: DateTime.now().toUtc(),
      updatedAt: state.updatedAt,
    );
  });

  Future<void> update(String packId) {
    final target = state.statuses[packId];
    if (target?.state != PackUpdateAvailability.updateAvailable) {
      return Future.value();
    }
    return _run(packId, (repository) async {
      await repository!.update(
        target!,
        cancellation: _cancellation,
        onProgress: (progress) {
          if (!_alive) return;
          state = PackUpdateBrowseState(
            statuses: state.statuses,
            checkedAt: state.checkedAt,
            updatedAt: state.updatedAt,
            busy: true,
            packId: packId,
            progress: progress,
            action: 'update',
          );
        },
      );
      if (!_alive) return;
      final runtime = ref.read(localContentRuntimeProvider);
      if (runtime == null) throw const PackDownloadFailure('storage');
      try {
        await runtime.reloadInstalled();
      } catch (_) {
        throw const PackDownloadFailure('projection-failed');
      }
      if (!_alive) return;
      ref.invalidate(contentRepositoryProvider);
      state = PackUpdateBrowseState(
        statuses: Map.unmodifiable({
          ...state.statuses,
          packId: PackUpdateStatus(
            packId: packId,
            installedRevision: target.revision!,
            revision: target.revision,
            manifestSha256: target.manifestSha256,
            state: PackUpdateAvailability.upToDate,
          ),
        }),
        checkedAt: state.checkedAt,
        updatedAt: DateTime.now().toUtc(),
      );
    }, actionName: 'update');
  }

  Future<void> removeDownload(Pack pack) => _run(
    pack.id,
    (_) async {
      _safeBoundary();
      final runtime = ref.read(localContentRuntimeProvider);
      if (runtime?.store == null) throw const PackDownloadFailure('storage');
      await runtime!.store!.removeDownload(
        pack.id,
        expectedRevision: pack.revision,
        checkCancelled: _safeBoundary,
      );
      await _refreshManagement(runtime);
      if (!_alive) return;
      state = PackUpdateBrowseState(
        statuses: Map.unmodifiable({...state.statuses}..remove(pack.id)),
        checkedAt: state.checkedAt,
        updatedAt: state.updatedAt,
      );
    },
    online: false,
    actionName: 'remove',
  );

  Future<void> cleanupStorage() => _run(
    null,
    (_) async {
      _safeBoundary();
      final runtime = ref.read(localContentRuntimeProvider);
      final store = runtime?.store;
      if (store == null) throw const PackDownloadFailure('storage');
      await runtime!.releasePlayback();
      await store.recoverInterruptedDownloads();
      _safeBoundary();
      await store.cleanupRetired();
      if (!_alive) return;
      state = PackUpdateBrowseState(
        statuses: state.statuses,
        checkedAt: state.checkedAt,
        updatedAt: state.updatedAt,
      );
    },
    online: false,
    actionName: 'cleanup',
  );

  void _safeBoundary() {
    _cancellation?.throwIfCancelled();
    if (!_alive || ref.read(gameplayNetworkBlockedProvider)) {
      throw const PackDownloadFailure('cancelled');
    }
  }

  Future<void> _refreshManagement(LocalContentRuntime runtime) async {
    await runtime.refreshRetirements();
    if (!_alive) return;
    ref.invalidate(contentRepositoryProvider);
    await runtime.releasePlayback();
    try {
      await runtime.reloadInstalled();
    } catch (_) {
      throw const PackDownloadFailure('projection-failed');
    }
    if (!_alive) return;
    ref.invalidate(contentRepositoryProvider);
    try {
      await runtime.store!.cleanupRetired();
    } on FileSystemException {
      /* Retry bounded cleanup at Home. */
    }
  }

  Future<void> _run(
    String? packId,
    Future<void> Function(PackUpdateRepository?) action, {
    bool online = true,
    String actionName = 'check',
  }) {
    if (!_alive) return Future.value();
    if (state.busy) return _pending ?? Future.value();
    final blocked = ref.read(gameplayNetworkBlockedProvider);
    final lease = ref.read(contentTransferOwnerProvider.notifier);
    if (blocked || lease.state != null) {
      _error(blocked ? 'gameplay-active' : 'transfer-busy');
      return Future.value();
    }
    final owner = Object();
    lease.state = owner;
    final done = Completer<void>();
    _pending = done.future;
    _cancellation = PackDownloadCancellation();
    state = PackUpdateBrowseState(
      statuses: state.statuses,
      checkedAt: state.checkedAt,
      updatedAt: state.updatedAt,
      busy: true,
      packId: packId,
      action: actionName,
    );
    unawaited(() async {
      try {
        final repository = online
            ? ref.read(packUpdateRepositoryProvider)
            : null;
        if (online && repository == null) {
          throw const PackDownloadFailure('updates-unavailable');
        }
        await action(repository);
      } on PackDownloadFailure catch (error) {
        if (_alive) _error(error.code);
      } on FileSystemException catch (error) {
        if (_alive) {
          _error(
            {28, 112}.contains(error.osError?.errorCode) ||
                    error.message.toLowerCase().contains('no space')
                ? 'no-space'
                : 'storage',
          );
        }
      } on StateError {
        if (_alive) _error('content-changed');
      } catch (_) {
        if (_alive) _error('update-failed');
      } finally {
        _cancellation = null;
        _pending = null;
        if (lease.mounted && identical(lease.state, owner)) lease.state = null;
        done.complete();
      }
    }());
    return done.future;
  }

  void _error(String error) {
    state = PackUpdateBrowseState(
      statuses: state.statuses,
      checkedAt: state.checkedAt,
      updatedAt: state.updatedAt,
      error: error,
    );
  }

  void cancel() => _cancellation?.cancel();
  Future<void> stopForGameplay() async {
    cancel();
    await _pending;
  }
}

final packUpdatesProvider =
    NotifierProvider<PackUpdateController, PackUpdateBrowseState>(
      PackUpdateController.new,
    );
