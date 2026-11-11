import 'dart:async';

import 'package:flutter/material.dart';

import '../data/dataset_controller.dart';
import '../data/dataset_store.dart';
import '../data/pack_summary.dart';
import '../data/studio_dataset.dart';
import 'pack_draft_dialog.dart';
import 'cards_page.dart';
import 'publication_review_dialog.dart';

class PacksPage extends StatefulWidget {
  const PacksPage({super.key, required this.controller});
  final DatasetController controller;
  @override
  State<PacksPage> createState() => _PacksPageState();
}

class _PacksPageState extends State<PacksPage> {
  final _search = TextEditingController();
  String _filter = 'all';
  String? _scope;
  @override
  void initState() {
    super.initState();
    _scope = widget.controller.scope?.namespace;
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(PacksPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      _changed();
    }
  }

  void _changed() {
    if (!mounted) return;
    if (_scope != widget.controller.scope?.namespace) {
      _scope = widget.controller.scope?.namespace;
      _search.clear();
      _filter = 'all';
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller.scope == null ||
        controller.snapshot == null ||
        !{
          DatasetPhase.ready,
          DatasetPhase.offline,
        }.contains(controller.phase)) {
      return const SizedBox.shrink();
    }
    final owner = controller.scope!.role == 'owner_admin';
    final query = _search.text.trim().toLowerCase();
    final rows = controller.packs
        .where(
          (pack) =>
              (pack.name.toLowerCase().contains(query) ||
                  pack.id.toLowerCase().contains(query)) &&
              switch (_filter) {
                'all' => true,
                'draft' => pack.isDraft,
                'pending' => pack.pending != null,
                'synced' => pack.pending == null,
                _ => pack.state == _filter,
              },
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
        Text(
          owner
              ? 'All Packs, including unassigned legacy content.'
              : 'Your Packs only. Ownership is assigned by the server.',
        ),
        const Text(
          'Save changes locally, then queue a commit explicitly. Nothing is uploaded here.',
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Search Packs',
            prefixIcon: Icon(Icons.search),
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey(controller.scope!.namespace),
          initialValue: _filter,
          decoration: const InputDecoration(labelText: 'Pack status'),
          isExpanded: true,
          items: [
            const DropdownMenuItem(value: 'all', child: Text('All statuses')),
            const DropdownMenuItem(value: 'active', child: Text('Active')),
            const DropdownMenuItem(value: 'hidden', child: Text('Hidden')),
            if (owner) ...[
              const DropdownMenuItem(value: 'deleted', child: Text('Deleted')),
              const DropdownMenuItem(
                value: 'purged',
                child: Text('Permanently deleted'),
              ),
            ],
            const DropdownMenuItem(value: 'draft', child: Text('Drafts')),
            const DropdownMenuItem(value: 'pending', child: Text('Pending')),
            const DropdownMenuItem(value: 'synced', child: Text('Synced')),
          ],
          onChanged: (value) => setState(() => _filter = value ?? 'all'),
        ),
        const SizedBox(height: 16),
        if (rows.isEmpty) const Text('No Packs match this view.'),
        for (final pack in rows)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    pack.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    '${pack.id} · ${pack.state} · ${pack.revision == 0 ? 'New local Pack' : 'Revision ${pack.revision}'}',
                  ),
                  Text(
                    'Topic: ${controller.topics.where((t) => t.id == pack.topicId).firstOrNull?.name ?? pack.topicId}',
                  ),
                  Text(
                    pack.pending == null ? 'Synced' : 'Pending local operation',
                  ),
                  if (owner)
                    Text(
                      'Creator: ${pack.revision == 0 ? 'Assigned by server on commit' : pack.createdByUid ?? 'Unassigned legacy draft'}',
                    ),
                  Text(
                    pack.isDraft
                        ? 'Draft — no eligible Cards; not playable or publishable'
                        : '${pack.eligibleCardCount} eligible Cards · publication status unknown',
                  ),
                  TextButton(
                    onPressed: () =>
                        showPackCards(context, controller, pack.id),
                    child: const Text('Review Cards'),
                  ),
                  if (pack.pending != null) ...[
                    Text(switch (pack.pending!.status) {
                      DraftStatus.draft => 'Draft — saved locally',
                      DraftStatus.unsent => 'Unsent commit — queued locally',
                      DraftStatus.conflict =>
                        'Conflict — review before queueing',
                    }),
                    Text('Pending change: ${pack.pending!.action}'),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        if (pack.pending!.status == DraftStatus.draft)
                          TextButton(
                            onPressed: () => _run(
                              context,
                              () => controller.queueDraft(pack.pending!.id),
                            ),
                            child: const Text('Queue commit'),
                          ),
                        if (pack.pending!.status != DraftStatus.conflict &&
                            {'create', 'update'}.contains(pack.pending!.action))
                          TextButton(
                            onPressed: () => _edit(context, pack),
                            child: const Text('Edit local draft'),
                          ),
                        TextButton(
                          onPressed: () => _run(
                            context,
                            () => controller.discardDraft(pack.pending!.id),
                          ),
                          child: const Text('Discard local change'),
                        ),
                      ],
                    ),
                  ] else
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        if ({'active', 'hidden'}.contains(pack.state) &&
                            pack.revision > 0)
                          TextButton(
                            onPressed: controller.phase == DatasetPhase.ready
                                ? () => showPublicationReview(
                                    context,
                                    controller,
                                    'pack',
                                    pack.id,
                                  )
                                : null,
                            child: const Text('Review publication'),
                          ),
                        if ({'active', 'hidden'}.contains(pack.state))
                          TextButton(
                            onPressed: () => _edit(context, pack),
                            child: const Text('Edit Pack'),
                          ),
                        if (pack.state == 'active')
                          TextButton(
                            onPressed: () => _run(
                              context,
                              () => controller.hidePack(
                                pack.id,
                                expectedRevision: pack.revision,
                              ),
                            ),
                            child: const Text('Hide Pack'),
                          ),
                        if (owner && {'active', 'hidden'}.contains(pack.state))
                          TextButton(
                            onPressed: () => _confirm(context, pack, 'delete'),
                            child: const Text('Delete Pack'),
                          ),
                        if (owner && pack.state == 'deleted') ...[
                          TextButton(
                            onPressed: () => _confirm(context, pack, 'restore'),
                            child: const Text('Restore Pack'),
                          ),
                          TextButton(
                            onPressed: () =>
                                _confirm(context, pack, 'permanently delete'),
                            child: const Text('Permanently delete Pack'),
                          ),
                        ],
                      ],
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  void _edit(BuildContext context, PackSummary pack) => showDialog<void>(
    context: context,
    builder: (_) => PackDraftDialog(controller: widget.controller, pack: pack),
  );
  void _confirm(BuildContext context, PackSummary pack, String action) =>
      showDialog<void>(
        context: context,
        builder: (_) => _PackConfirmation(
          controller: widget.controller,
          pack: pack,
          action: action,
        ),
      );
}

String packFailureMessage(Object error) =>
    switch (error is DatasetStorageFailure ? error.code : '') {
      'forbidden' || 'storage-closed' => 'This workspace no longer permits that action. Check access before retrying.',
      'pack-pending-change' => 'This Pack already has a pending operation. Discard it before another action.',
      'pack-has-pending-children' =>
        'Local Card changes depend on this Pack. Resolve those changes first.',
      'pack-has-children' => 'Permanently delete the contained Cards first. This Pack has been retained.',
      'topic-not-eligible' || 'invalid-pack-state' => 'The Pack or its Topic is no longer eligible. Refresh and review the dataset.',
      'draft-conflict' || 'storage-conflict' => 'This change conflicts with newer data. Refresh and review before queueing it.',
      'pack-topic-immutable' || 'invalid-draft' =>
        'Enter a valid Pack name and keep the synchronized Topic association.',
      'quota-exceeded' => 'Browser storage is full. Your text and last saved data are retained; free storage and retry.',
      _ => 'Could not save locally. Your text and last saved data are retained; check browser storage and retry.',
    };

Future<void> _run(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(packFailureMessage(error))));
    }
  }
}

class _PackConfirmation extends StatefulWidget {
  const _PackConfirmation({
    required this.controller,
    required this.pack,
    required this.action,
  });
  final DatasetController controller;
  final PackSummary pack;
  final String action;
  @override
  State<_PackConfirmation> createState() => _PackConfirmationState();
}

class _PackConfirmationState extends State<_PackConfirmation> {
  late final String? _scope;
  bool _closed = false;
  bool _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _scope = widget.controller.scope?.namespace;
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (_closed ||
        widget.controller.scope?.namespace == _scope &&
            widget.controller.scope?.role == 'owner_admin') {
      return;
    }
    _closed = true;
    if (mounted) {
      setState(() {});
      scheduleMicrotask(() {
        if (mounted) Navigator.of(context).pop();
      });
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final controller = widget.controller;
      final pack = widget.pack;
      switch (widget.action) {
        case 'delete':
          await controller.deletePack(pack.id, expectedRevision: pack.revision);
        case 'restore':
          await controller.restorePack(
            pack.id,
            expectedRevision: pack.revision,
          );
        case 'permanently delete':
          await controller.purgePack(pack.id, expectedRevision: pack.revision);
      }
      if (mounted && !_closed) Navigator.of(context).pop();
    } catch (error) {
      if (mounted && !_closed) {
        setState(() {
          _saving = false;
          _error = packFailureMessage(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_closed) return const SizedBox.shrink();
    final action = widget.action;
    return AlertDialog(
      title: Text('${action[0].toUpperCase()}${action.substring(1)} Pack?'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.pack.name),
              const SizedBox(height: 12),
              Text(switch (action) {
                'delete' => 'Soft deletion will also delete contained Cards when committed. IDs and relationships are retained.',
                'restore' => 'Restore only this Pack into hidden state. Its Topic must be eligible. Cards remain unchanged.',
                _ => 'Permanent deletion cannot be undone after upload. Contained Cards must already be permanently deleted.',
              }),
              const SizedBox(height: 12),
              const Text(
                'This saves a pending local operation. Queue it explicitly afterward; no server data changes here.',
              ),
              if (_error != null)
                Semantics(liveRegion: true, child: Text(_error!)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving locally…' : 'Confirm local $action'),
        ),
      ],
    );
  }
}
