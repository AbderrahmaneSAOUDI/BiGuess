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
    this.installed = false,
    this.progress,
    this.error,
  });
  final bool busy, installed;
  final PackDownloadProgress? progress;
  final String? error;
}

class PackDownloadController extends Notifier<Map<String, PackDownloadState>> {
  bool _alive = true;
  @override
  Map<String, PackDownloadState> build() {
    _alive = true;
    ref.onDispose(() => _alive = false);
    return const {};
  }

  void _set(String id, PackDownloadState next) {
    if (_alive) state = {...state, id: next};
  }

  /// One foreground operation. No queue, automatic retry or launch work.
  Future<void> download(CatalogPackSummary summary) async {
    if (state.values.any((s) => s.busy)) return;
    final repository = ref.read(packDownloadRepositoryProvider);
    if (repository == null) {
      _set(summary.id, const PackDownloadState(error: 'storage-unavailable'));
      return;
    }
    _set(summary.id, const PackDownloadState(busy: true));
    try {
      await repository.download(
        summary,
        onProgress: (progress) {
          _set(summary.id, PackDownloadState(busy: true, progress: progress));
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
