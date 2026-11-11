import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/download/pack_download_repository.dart';
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
  });
  final Map<String, PackUpdateStatus> statuses;
  final DateTime? checkedAt, updatedAt;
  final bool busy;
  final String? packId, error;
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
    final results = await repository.check(cancellation: _cancellation);
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
      await repository.update(
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
    });
  }

  Future<void> _run(
    String? packId,
    Future<void> Function(PackUpdateRepository) action,
  ) {
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
    );
    unawaited(() async {
      try {
        final repository = ref.read(packUpdateRepositoryProvider);
        if (repository == null) {
          throw const PackDownloadFailure('updates-unavailable');
        }
        await action(repository);
      } on PackDownloadFailure catch (error) {
        if (_alive) _error(error.code);
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
