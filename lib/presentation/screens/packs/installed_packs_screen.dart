import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/updates/pack_update_repository.dart';
import '../../../providers/content_transfer_gate.dart';
import '../../../providers/gameplay_network_gate.dart';
import '../../../providers/pack_update_controller.dart';

/// Home-owned management. Rendering this screen performs no network work.
class InstalledPacksScreen extends ConsumerWidget {
  const InstalledPacksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final packs = ref.watch(installedDownloadPacksProvider);
    final state = ref.watch(packUpdatesProvider);
    final blocked = ref.watch(gameplayNetworkBlockedProvider);
    final canRequest =
        !blocked &&
        !state.busy &&
        ref.watch(contentTransferOwnerProvider) == null;
    final controller = ref.read(packUpdatesProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: const Text('Installed Packs')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: canRequest && packs.isNotEmpty
                      ? controller.check
                      : null,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Check for updates'),
                ),
                if (state.busy)
                  TextButton(
                    onPressed: controller.cancel,
                    child: const Text('Cancel'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Updates are optional. Your installed Packs stay ready offline until you choose Update.',
            ),
            if (state.checkedAt != null)
              Text('Last checked: ${state.checkedAt!.toLocal()}'),
            if (state.updatedAt != null)
              Text('Last updated: ${state.updatedAt!.toLocal()}'),
            if (state.busy) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: (state.progress?.totalBytes ?? 0) > 0
                    ? (state.progress!.receivedBytes /
                              state.progress!.totalBytes)
                          .clamp(0, 1)
                    : null,
              ),
              Text(
                state.packId == null
                    ? 'Checking for updates…'
                    : state.progress == null
                    ? 'Preparing update…'
                    : '${state.progress!.phase.name}: ${state.progress!.receivedBytes} / ${state.progress!.totalBytes} bytes',
              ),
            ],
            if (state.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _error(state.error!),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
            if (packs.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 24),
                child: Text(
                  'No downloaded Packs yet. Choose a Topic to download a Pack.',
                ),
              ),
            for (final pack in packs)
              Builder(
                builder: (context) {
                  final result = state.statuses[pack.id];
                  final status = result?.installedRevision == pack.revision
                      ? result?.state
                      : null;
                  final label = switch (status) {
                    PackUpdateAvailability.upToDate => 'Up to date',
                    PackUpdateAvailability.updateAvailable =>
                      'Update available',
                    PackUpdateAvailability.unavailable ||
                    PackUpdateAvailability.deleted ||
                    PackUpdateAvailability.unknown => 'Unavailable online',
                    null => 'Not checked',
                  };
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            pack.name,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text('Installed · revision ${pack.revision}'),
                          Text(label),
                          if (status == PackUpdateAvailability.updateAvailable)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: OutlinedButton.icon(
                                key: ValueKey('update-${pack.id}'),
                                onPressed: canRequest
                                    ? () => controller.update(pack.id)
                                    : null,
                                icon: const Icon(Icons.system_update_alt),
                                label: const Text('Update'),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  String _error(String code) => switch (code) {
    'cancelled' =>
      'Update cancelled. Check or choose Update again when ready. Installed content remains available.',
    'gameplay-active' => 'Return to Packs before checking or updating content.',
    'transfer-busy' =>
      'Wait for the current download to finish, or cancel it before checking for updates.',
    'updates-unavailable' =>
      'Online updates are unavailable. Installed Packs remain ready offline.',
    'delta-unavailable' =>
      'Incremental history is unavailable for this Pack. Its installed revision remains ready offline.',
    'no-space' =>
      'Not enough private storage. Free some space and choose Update again.',
    'untrusted-key' =>
      'The publisher key is not trusted by this app. The update was not installed.',
    'corrupt' =>
      'The update failed verification. The installed revision was kept. Check for updates before retrying.',
    'timeout' || 'offline' =>
      'Online updates could not be reached. Check your connection and retry. Installed Packs remain ready offline.',
    'projection-failed' =>
      'The verified update was saved, but the local view could not be refreshed. Restart the app to reopen it.',
    _ =>
      'The update could not be checked or installed. Check for updates again. Installed content remains available.',
  };
}
