import 'dart:async';

import 'package:flutter/material.dart';

import '../app/studio_route.dart';
import '../data/dataset_controller.dart';
import '../data/studio_dataset.dart';
import 'topics_page.dart';
import 'pack_draft_dialog.dart';

/// First-sync workspace. Full Topic/Pack/Card authoring remains in later tickets.
class DatasetPage extends StatelessWidget {
  const DatasetPage({super.key, required this.route, required this.controller});

  final StudioRoute route;
  final DatasetController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final snapshot = controller.snapshot;
      final ready =
          snapshot != null &&
          {DatasetPhase.ready, DatasetPhase.offline}.contains(controller.phase);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              route.label,
              style: Theme.of(context).textTheme.headlineLarge,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.tonal(
                onPressed: controller.busy ? null : controller.refresh,
                child: const Text('Refresh dataset'),
              ),
              Text(
                snapshot?.lastSyncedAt == null
                    ? 'No complete sync yet'
                    : 'Last complete sync: ${snapshot!.lastSyncedAt!.toLocal()}',
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (controller.busy)
            Semantics(
              liveRegion: true,
              label: 'Loading authorized dataset',
              child: const LinearProgressIndicator(),
            ),
          if (controller.phase == DatasetPhase.offline) ...[
            const Text(
              'Offline workspace — local edits only. Access was verified before '
              'the last complete sync. Revocation cannot be detected offline; '
              'reconnecting checks access before showing content.',
            ),
            const SizedBox(height: 12),
          ],
          if (controller.errorCode != null) ...[
            Semantics(
              liveRegion: true,
              child: Text(_errorMessage(controller.errorCode!)),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: controller.busy ? null : controller.retryStorage,
                child: const Text('Retry storage'),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (ready) ...[
            if (route == StudioRoute.profile)
              Text(
                'Account: ${snapshot.scope.uid}\n'
                'Role: ${snapshot.scope.role == 'owner_admin' ? 'Owner' : 'Collector'}',
              ),
            if (route == StudioRoute.dashboard) ...[
              Text(
                '${snapshot.records.length} synchronized records · '
                '${snapshot.drafts.length} local drafts or queued changes',
              ),
              const SizedBox(height: 8),
              const Text(
                'Edits are saved on this browser. Queueing marks an unsent '
                'commit; it does not upload changes. Publishing status is not '
                'supplied by the administrative dataset.',
              ),
            ],
            if (route == StudioRoute.topics) TopicsPage(controller: controller),
            if (route == StudioRoute.myPacks) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonal(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => PackDraftDialog(controller: controller),
                  ),
                  child: const Text('New Pack draft'),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if ({StudioRoute.myPacks, StudioRoute.cards}.contains(route))
              _RecordList(controller: controller, route: route),
            if (route == StudioRoute.dashboard && snapshot.drafts.isNotEmpty)
              _DraftList(controller: controller, drafts: snapshot.drafts),
          ] else if (!controller.busy)
            const Text(
              'No authorized browser dataset is open. Complete an online '
              'access check and sync before using an offline workspace.',
            ),
          const SizedBox(height: 24),
          const Text(
            'Browser storage is local to this site and device. Quota limits, '
            'private browsing, eviction or cleared site data can remove saved '
            'content and unsent drafts. A first visit needs online authorization. '
            'Sign-out and account switching close the workspace immediately; '
            'another account cannot open its data. Offline reopening also needs '
            'the app shell and the previously restored identity to remain available.',
          ),
        ],
      );
    },
  );
}

class _RecordList extends StatelessWidget {
  const _RecordList({required this.controller, required this.route});
  final DatasetController controller;
  final StudioRoute route;

  @override
  Widget build(BuildContext context) {
    final kind = switch (route) {
      StudioRoute.topics => 'topic',
      StudioRoute.myPacks => 'pack',
      _ => 'card',
    };
    final snapshot = controller.snapshot!;
    final records = snapshot.records
        .where((record) => record['resourceType'] == kind)
        .toList();
    final drafts = snapshot.drafts
        .where((draft) => draft.resourceType == kind)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (records.isEmpty)
          const Text('No synchronized records in this view.'),
        for (final record in records) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${record['name'] ?? record['id']}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Synced · Revision ${record['revision']} · '
                    '${record['state']}',
                  ),
                  if (kind != 'topic' &&
                      !{'deleted', 'purged'}.contains(record['state']))
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => _edit(context, controller, record),
                        child: const Text('Edit name locally'),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],
        if (drafts.isNotEmpty)
          _DraftList(controller: controller, drafts: drafts),
      ],
    );
  }
}

class _DraftList extends StatelessWidget {
  const _DraftList({required this.controller, required this.drafts});
  final DatasetController controller;
  final List<LocalDraft> drafts;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 16),
      Text('Local changes', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      for (final draft in drafts) ...[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('${draft.value['name'] ?? draft.resourceId}'),
                Text(switch (draft.status) {
                  DraftStatus.draft => 'Draft — saved locally',
                  DraftStatus.unsent => 'Unsent commit — queued locally',
                  DraftStatus.conflict => 'Conflict — review before queueing',
                }),
                Text(
                  'Pending change: ${switch (draft.action) {
                    'create' => 'Create',
                    'hide' => 'Hide',
                    'softDelete' => 'Delete',
                    'restore' => 'Restore',
                    _ => 'Edit',
                  }}',
                ),
                Text(
                  'Base revision: ${draft.baseRevision ?? 'new draft'} · '
                  'Published revision: ${draft.publishedRevision ?? 'unknown'}',
                ),
                Wrap(
                  spacing: 12,
                  children: [
                    if (draft.status == DraftStatus.draft)
                      TextButton(
                        onPressed: () => _action(
                          context,
                          () => controller.queueDraft(draft.id),
                        ),
                        child: const Text('Queue commit'),
                      ),
                    if (draft.status != DraftStatus.conflict &&
                        draft.resourceType != 'topic')
                      TextButton(
                        onPressed: () {
                          if (draft.resourceType == 'pack' &&
                              draft.action == 'create') {
                            showDialog<void>(
                              context: context,
                              builder: (_) => PackDraftDialog(
                                controller: controller,
                                draft: draft,
                              ),
                            );
                            return;
                          }
                          final record = controller.snapshot!.records
                              .where(
                                (record) =>
                                    record['resourceType'] ==
                                        draft.resourceType &&
                                    record['id'] == draft.resourceId,
                              )
                              .firstOrNull;
                          if (record != null) {
                            _edit(
                              context,
                              controller,
                              record,
                              initialName: draft.value['name'] as String?,
                            );
                          }
                        },
                        child: const Text('Edit local draft'),
                      ),
                    TextButton(
                      onPressed: () => _action(
                        context,
                        () => controller.discardDraft(draft.id),
                      ),
                      child: const Text('Discard local change'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
      ],
    ],
  );
}

Future<void> _action(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'The local change was not saved. Check browser storage and retry.',
        ),
      ),
    );
  }
}

Future<void> _edit(
  BuildContext context,
  DatasetController controller,
  Map<String, Object?> record, {
  String? initialName,
}) => showDialog<void>(
  context: context,
  builder: (_) => _NameEditor(
    controller: controller,
    record: record,
    initialName: initialName,
  ),
);

class _NameEditor extends StatefulWidget {
  const _NameEditor({
    required this.controller,
    required this.record,
    this.initialName,
  });
  final DatasetController controller;
  final Map<String, Object?> record;
  final String? initialName;
  @override
  State<_NameEditor> createState() => _NameEditorState();
}

class _NameEditorState extends State<_NameEditor> {
  late final String? _scope;
  late final _name = TextEditingController(
    text: widget.initialName ?? widget.record['name'] as String? ?? '',
  );
  bool _saving = false;
  bool _closed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scope = widget.controller.scope?.namespace;
    widget.controller.addListener(_scopeChanged);
  }

  void _scopeChanged() {
    if (_closed || widget.controller.scope?.namespace == _scope) return;
    _closed = true;
    _name.clear();
    if (mounted) {
      setState(() {});
      scheduleMicrotask(() {
        if (mounted) Navigator.of(context).pop();
      });
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_scopeChanged);
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a name.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.controller.saveDraft(widget.record, name: name);
      if (mounted && !_closed) Navigator.of(context).pop();
    } catch (_) {
      if (!mounted || _closed) return;
      setState(() {
        _saving = false;
        _error =
            'Could not save locally. Your text is still here. '
            'Free browser storage or retry when storage is available.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => _closed
      ? const SizedBox.shrink()
      : AlertDialog(
          title: const Text('Edit local name'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _name,
                  autofocus: true,
                  enabled: !_saving,
                  decoration: const InputDecoration(labelText: 'Name'),
                  onSubmitted: (_) {
                    if (!_saving) _save();
                  },
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Semantics(liveRegion: true, child: Text(_error!)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving locally…' : 'Save locally'),
            ),
          ],
        );
}

String _errorMessage(String code) => switch (code) {
  'quota' || 'storage-quota' || 'quota-exceeded' =>
    'Browser storage is full. Your last saved dataset and drafts are retained. '
        'Free site storage without clearing these drafts, then retry.',
  'storage-conflict' =>
    'Another tab changed this workspace. Reload its saved dataset before retrying; '
        'this tab has not overwritten those changes.',
  'storage-blocked' || 'storage-version' || 'corrupt' || 'storage-corrupt' =>
    'Browser storage is unavailable or incompatible. Existing saved data has '
        'not been replaced. Enable site storage or use a supported browser and retry.',
  'forbidden' || 'session-expired' =>
    'Access is no longer authorized. Sign in again before opening any content.',
  'cursor_expired' =>
    'The sync snapshot expired. Refresh to restart; the last complete saved '
        'dataset and local drafts remain intact.',
  _ =>
    'Could not complete the operation. The last complete saved dataset and '
        'drafts have not been replaced. Check the connection or browser storage and retry.',
};
