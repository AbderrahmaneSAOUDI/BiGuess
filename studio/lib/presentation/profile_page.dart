import 'package:flutter/material.dart';

import '../auth/studio_session.dart';
import '../data/profile_api.dart';
import '../data/profile_controller.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key, required this.controller});
  final ProfileController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, controller.session]),
    builder: (context, _) {
      final principal = controller.session.principal;
      final profile = controller.profile;
      final online = controller.session.phase == SessionPhase.authorized;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (principal != null) ...[
            Text('Email: ${principal.email}'),
            Text('Account ID: ${principal.uid}'),
            Text(
              'Role: ${principal.role == 'owner_admin' ? 'Owner' : 'Collector'}',
            ),
          ],
          if (!online)
            const Text(
              'Reconnect to verify your identity, role and contribution statistics.',
            ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonal(
              onPressed: controller.loading || !online
                  ? null
                  : () => controller.refresh(),
              child: const Text('Refresh profile'),
            ),
          ),
          const SizedBox(height: 12),
          if (controller.loading) const LinearProgressIndicator(),
          if (controller.errorCode != null)
            Semantics(
              liveRegion: true,
              child: Text(
                controller.errorCode == 'cursor_expired'
                    ? 'The activity snapshot expired. Refresh profile to start a new snapshot.'
                    : 'Could not load contribution statistics. Check the connection and retry Refresh profile.',
              ),
            ),
          if (profile == null && !controller.loading)
            const Text(
              'Refresh profile to load validated contributions from the server. '
              'Local drafts and queued changes are not counted.',
            ),
          if (profile != null) ...[
            Text('Activity snapshot: ${profile.asOf.toLocal()}'),
            const SizedBox(height: 12),
            Text(
              profile.principal.role == 'collector'
                  ? 'Your contributions'
                  : profile.contributorUid == null
                  ? 'All contributors'
                  : 'Contributions by ${profile.contributorUid}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Counts reflect validated content operations, including audited cascading removals. '
              'Hiding or deleting content does not erase earlier contributions. '
              'Permanent deletion is counted separately from removal.',
            ),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                for (final entry in ContributionCounts.labels.entries)
                  SizedBox(
                    width: 215,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          '${entry.value}: ${profile.counts.values[entry.key]}',
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            if (profile.principal.role == 'owner_admin') ...[
              const SizedBox(height: 20),
              Text(
                'Contributors',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              for (final contributor in profile.contributors)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(contributor.email ?? contributor.uid),
                        Text('Account ID: ${contributor.uid}'),
                        Text(
                          contributor.role == null
                              ? 'No current Studio access'
                              : 'Role: ${contributor.role == 'owner_admin' ? 'Owner' : 'Collector'}',
                        ),
                        Text(
                          'Validated operations: ${contributor.counts.values['totalOperations']}',
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: controller.loading
                                ? null
                                : () => controller.refresh(
                                    contributorUid: contributor.uid,
                                  ),
                            child: const Text('View contributor activity'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 20),
            Text(
              'Validated activity',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (profile.activity.isEmpty)
              const Text('No validated operations in this view.'),
            for (final activity in profile.activity)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '${_actionLabel(activity.action)} · ${activity.resourceType} · ${activity.resourceId}',
                      ),
                      if (profile.principal.role == 'owner_admin')
                        Text(
                          'Actor: ${activity.actorId} · role at commit: '
                          '${activity.actorRole == 'owner_admin' ? 'Owner' : 'Collector'}',
                        ),
                      Text(
                        'Revision ${activity.revision} · ${activity.committedAt.toLocal()}',
                      ),
                    ],
                  ),
                ),
              ),
            if (profile.nextCursor != null)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: controller.loading
                      ? null
                      : () => controller.refresh(more: true),
                  child: const Text('Load more activity'),
                ),
              ),
          ],
        ],
      );
    },
  );
}

String _actionLabel(String action) => switch (action) {
  'create' => 'Created',
  'update' => 'Edited',
  'hide' => 'Hidden',
  'activate' => 'Activated',
  'softDelete' => 'Removed',
  'restore' => 'Restored',
  'permanentDelete' => 'Permanently deleted',
  _ => action,
};
