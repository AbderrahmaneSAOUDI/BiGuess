import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/catalog/catalog_models.dart';
import '../../../providers/pack_download_controller.dart';

class PackDownloadAction extends ConsumerWidget {
  const PackDownloadAction({
    super.key,
    required this.summary,
    this.update = false,
  });
  final CatalogPackSummary summary;
  final bool update;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloads = ref.watch(packDownloadsProvider);
    final state = downloads[summary.id] ?? const PackDownloadState();
    return TextButton.icon(
      key: ValueKey('download-${summary.id}'),
      onPressed: () {
        showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => _DownloadSheet(summary: summary),
        );
        if (!state.busy) {
          ref.read(packDownloadsProvider.notifier).download(summary);
        }
      },
      icon: const Icon(Icons.download_rounded, size: 18),
      label: Text(
        state.queued
            ? 'Queued'
            : state.busy
            ? 'Progress'
            : update
            ? 'Download update'
            : 'Download',
      ),
    );
  }
}

class _DownloadSheet extends ConsumerWidget {
  const _DownloadSheet({required this.summary});
  final CatalogPackSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state =
        ref.watch(packDownloadsProvider)[summary.id] ??
        const PackDownloadState();
    final progress = state.progress;
    final total = progress?.totalBytes ?? 0;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(summary.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            if (state.busy) ...[
              LinearProgressIndicator(
                value: total > 0
                    ? (progress!.receivedBytes / total).clamp(0, 1)
                    : null,
              ),
              const SizedBox(height: 12),
              Text(
                state.queued
                    ? 'Queued. One download runs at a time.'
                    : state.cancelling
                    ? 'Cancellation requested…'
                    : progress == null
                    ? 'Preparing download…'
                    : '${progress.phase.name}: ${progress.receivedBytes} / $total bytes',
              ),
              const Text(
                'You can close this sheet. The download continues while the app stays open.',
              ),
              TextButton.icon(
                onPressed: state.cancelling
                    ? null
                    : () => ref
                          .read(packDownloadsProvider.notifier)
                          .cancel(summary.id),
                icon: const Icon(Icons.cancel_outlined),
                label: Text(
                  state.queued ? 'Cancel queued download' : 'Cancel download',
                ),
              ),
            ],
            if (state.installed)
              const Text('Installed. This Pack is ready to play offline.'),
            if (state.error != null) ...[
              Semantics(liveRegion: true, child: Text(_error(state.error!))),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: state.busy
                    ? null
                    : () => ref
                          .read(packDownloadsProvider.notifier)
                          .download(summary),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry download'),
              ),
            ],
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  String _error(String code) => switch (code) {
    'cancelled' =>
      'Download cancelled. Existing installed Packs remain available. Retry starts a fresh download.',
    'queue-full' =>
      'The download queue is full. Wait for a download to finish or cancel a queued download, then retry.',
    'no-space' => 'Not enough private storage. Free some space and retry.',
    'untrusted-key' || 'untrusted' =>
      'The publisher key is not trusted by this app. The Pack was not installed.',
    'timeout' => 'The download timed out. Check your connection and retry.',
    'offline' || 'network' =>
      'The download could not connect. Check your connection and retry.',
    'unavailable' =>
      'This Pack is no longer available for download. Refresh the catalog.',
    'corrupt' || 'invalid-pack' || 'invalid-receipt' =>
      'The Pack failed verification. It was not installed. Retry to download a fresh copy.',
    'quota' || 'pack-limit' || 'limit' =>
      'Free storage allows up to 5 downloaded Packs. Your existing Packs remain available.',
    'catalog-changed' =>
      'The catalog changed. Refresh the catalog before trying this download again.',
    'storage-unavailable' =>
      'Private Pack storage is unavailable. Existing local content remains available.',
    'projection-failed' =>
      'The verified Pack was saved, but the local content view could not be updated. Retry or restart the app.',
    _ =>
      'The Pack could not be downloaded or verified. Existing installed content remains available. Retry to download a fresh copy.',
  };
}
