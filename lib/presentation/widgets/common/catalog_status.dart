import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/catalog_controller.dart';

/// Explicit discovery controls. Rendering this widget only reads saved state.
class CatalogStatus extends ConsumerWidget {
  const CatalogStatus({super.key, this.topicId});
  final String? topicId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(catalogBrowseProvider);
    if (!state.configured) return const SizedBox.shrink();
    final controller = ref.read(catalogBrowseProvider.notifier);
    final known =
        topicId == null ||
        (state.snapshot?.topics.any((t) => t.id == topicId) ?? false);
    if (!known) return const SizedBox.shrink();
    final checked = topicId == null
        ? state.snapshot?.topicsCheckedAt
        : state.snapshot?.packsCheckedAt[topicId];
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: state.loading
                    ? null
                    : () {
                        if (topicId == null) {
                          controller.refreshTopics();
                        } else {
                          controller.refreshPacks(topicId!);
                        }
                      },
                icon: const Icon(Icons.refresh_rounded),
                label: Text(
                  topicId != null
                      ? 'Refresh online Packs'
                      : checked == null
                      ? 'Discover online content'
                      : 'Refresh catalog',
                ),
              ),
              if (checked != null)
                Text(
                  'Saved catalog: ${checked.toLocal()}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
          if (state.loading)
            const LinearProgressIndicator(
              semanticsLabel: 'Loading catalog summaries',
            ),
          if (state.error != null)
            Semantics(
              liveRegion: true,
              child: Text(
                state.error == 'cache-unavailable'
                    ? 'Saved catalog could not be opened. Local Packs remain available; refresh to retry.'
                    : state.snapshot == null
                    ? 'Online content could not be loaded. Local Packs remain available.'
                    : 'Online content could not be refreshed. Showing saved summaries and local Packs.',
              ),
            ),
          if (state.snapshot != null)
            const Text(
              'Saved summaries may be out of date. Installed Packs stay available offline.',
            ),
        ],
      ),
    );
  }
}
