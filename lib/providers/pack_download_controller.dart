import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/catalog/catalog_models.dart';
import '../data/download/pack_download_repository.dart';
import 'catalog_controller.dart';
import 'topic_pack_providers.dart';

/// Build-pinned public SPKI keys, never learned from downloaded content.
final packDownloadKeysProvider = Provider<Map<String, String>>((ref) {
  const raw = String.fromEnvironment(
    'BIGUESS_CONTENT_PUBLIC_KEYS',
    defaultValue: '{}',
  );
  try {
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic> ||
        value.values.any((v) => v is! String)) {
      return const {};
    }
    return Map<String, String>.unmodifiable(value.cast<String, String>());
  } catch (_) {
    return const {};
  }
});

final packDownloadRepositoryProvider = Provider<PackDownloadRepository?>((ref) {
  final base = ref.watch(publicCatalogBaseUriProvider);
  final store = ref.watch(localContentRuntimeProvider)?.store;
  if (base == null || store == null) return null;
  final repository = HttpPackDownloadRepository(
    base: base,
    store: store,
    pinnedKeys: ref.watch(packDownloadKeysProvider),
  );
  ref.onDispose(repository.close);
  return repository;
});

class PackDownloadState {
  const PackDownloadState({
    this.busy = false,
    this.queued = false,
    this.cancelling = false,
    this.installed = false,
    this.progress,
    this.error,
  });
  final bool busy, queued, cancelling, installed;
  final PackDownloadProgress? progress;
  final String? error;
}

class _PackDownloadJob {
  _PackDownloadJob(this.summary);
  final CatalogPackSummary summary;
  final cancellation = PackDownloadCancellation();
  final done = Completer<void>();
}

class PackDownloadController extends Notifier<Map<String, PackDownloadState>> {
  static const maxQueuedJobs = 3;
  final _queue = Queue<_PackDownloadJob>();
  _PackDownloadJob? _active;
  bool _alive = true, _draining = false;

  @override
  Map<String, PackDownloadState> build() {
    _alive = true;
    ref.onDispose(() {
      _alive = false;
      _active?.cancellation.cancel();
      for (final job in _queue) {
        job.cancellation.cancel();
        job.done.complete();
      }
      _queue.clear();
    });
    return const {};
  }

  void _set(String id, PackDownloadState next) {
    if (_alive) state = {...state, id: next};
  }

  /// One active transfer and at most three explicit waiting requests. Queued
  /// jobs are memory-only: a restart requires a new user action, never HTTP.
  Future<void> download(CatalogPackSummary summary) {
    if (!_alive) return Future.value();
    final active = _active;
    if (active?.summary.id == summary.id) return active!.done.future;
    for (final job in _queue) {
      if (job.summary.id == summary.id) return job.done.future;
    }
    if (_queue.length >= maxQueuedJobs) {
      _set(summary.id, const PackDownloadState(error: 'queue-full'));
      return Future.value();
    }
    final job = _PackDownloadJob(summary);
    _queue.add(job);
    _set(summary.id, const PackDownloadState(busy: true, queued: true));
    unawaited(_drain());
    return job.done.future;
  }

  void cancel(String packId) {
    final active = _active;
    if (active?.summary.id == packId) {
      active!.cancellation.cancel();
      _set(
        packId,
        PackDownloadState(
          busy: true,
          cancelling: true,
          progress: state[packId]?.progress,
        ),
      );
      return;
    }
    final queued = _queue.where((job) => job.summary.id == packId).firstOrNull;
    if (queued != null) {
      _queue.remove(queued);
      queued.cancellation.cancel();
      queued.done.complete();
      _set(packId, const PackDownloadState(error: 'cancelled'));
    }
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_alive && _queue.isNotEmpty) {
        final job = _queue.removeFirst();
        _active = job;
        try {
          await _perform(job);
        } finally {
          _active = null;
          job.done.complete();
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _perform(_PackDownloadJob job) async {
    final summary = job.summary;
    _set(summary.id, const PackDownloadState(busy: true));
    try {
      final repository = ref.read(packDownloadRepositoryProvider);
      if (repository == null) {
        _set(summary.id, const PackDownloadState(error: 'storage-unavailable'));
        return;
      }
      await repository.download(
        summary,
        cancellation: job.cancellation,
        onProgress: (progress) {
          _set(
            summary.id,
            PackDownloadState(
              busy: true,
              cancelling: job.cancellation.isCancelled,
              progress: progress,
            ),
          );
        },
      );
      if (!_alive) return;
      final runtime = ref.read(localContentRuntimeProvider);
      if (runtime == null) throw StateError('Local runtime unavailable');
      try {
        await runtime.reloadInstalled();
      } catch (_) {
        _set(summary.id, const PackDownloadState(error: 'projection-failed'));
        return;
      }
      if (!_alive) return;
      ref.invalidate(contentRepositoryProvider);
      _set(summary.id, const PackDownloadState(installed: true));
    } on PackDownloadFailure catch (error) {
      _set(summary.id, PackDownloadState(error: error.code));
    } catch (_) {
      _set(summary.id, const PackDownloadState(error: 'download-failed'));
    }
  }
}

final packDownloadsProvider =
    NotifierProvider<PackDownloadController, Map<String, PackDownloadState>>(
      PackDownloadController.new,
    );
