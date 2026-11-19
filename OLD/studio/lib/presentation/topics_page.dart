import 'dart:async';

import 'package:flutter/material.dart';

import '../data/dataset_controller.dart';
import '../data/dataset_store.dart';
import '../data/studio_dataset.dart';
import '../data/topic_taxonomy.dart';
import 'publication_review_dialog.dart';

class TopicsPage extends StatefulWidget {
  const TopicsPage({super.key, required this.controller});
  final DatasetController controller;
  @override
  State<TopicsPage> createState() => _TopicsPageState();
}

class _TopicsPageState extends State<TopicsPage> {
  final _search = TextEditingController();
  String _state = 'all';
  String? _scope;
  @override
  void initState() {
    super.initState();
    _scope = widget.controller.scope?.namespace;
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(TopicsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  void _changed() {
    if (!mounted) return;
    if (_scope != widget.controller.scope?.namespace) {
      _scope = widget.controller.scope?.namespace;
      _search.clear();
      _state = 'all';
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
    final owner = controller.scope?.role == 'owner_admin';
    final ready =
        controller.snapshot != null &&
        {DatasetPhase.ready, DatasetPhase.offline}.contains(controller.phase);
    if (!ready) return const SizedBox.shrink();
    final query = _search.text.trim().toLowerCase();
    final rows = controller.topics
        .where(
          (topic) =>
              (owner || {'active', 'hidden'}.contains(topic.state)) &&
              (_state == 'all' || topic.state == _state) &&
              (topic.name.toLowerCase().contains(query) ||
                  topic.id.toLowerCase().contains(query)),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (owner)
              FilledButton(
                onPressed: () => _nameDialog(context, controller),
                child: const Text('New Topic'),
              ),
            Text(
              owner
                  ? 'Save Topic changes locally, then queue them explicitly. Nothing is uploaded here.'
                  : 'Permitted classification taxonomy. Topic administration is restricted to the Owner.',
            ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _search,
          decoration: const InputDecoration(labelText: 'Search Topics'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _state,
          key: ValueKey('$_scope:$_state'),
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Topic state'),
          items: [
            for (final entry in {
              'all': 'All states',
              'active': 'Active',
              'hidden': 'Hidden',
              if (owner) 'deleted': 'Deleted',
              if (owner) 'purged': 'Purged',
            }.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged: (value) {
            if (value != null) setState(() => _state = value);
          },
        ),
        const SizedBox(height: 16),
        if (rows.isEmpty) const Text('No Topics match this view.'),
        for (final topic in rows) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    topic.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${topic.id} · ${topic.state} · ${topic.revision == 0 ? 'New local Topic' : 'Revision ${topic.revision}'}',
                  ),
                  if (owner && topic.pending != null) ...[
                    Text(
                      '${_status(topic.pending!.status)} · ${_actionLabel(topic.pending!.action)}',
                    ),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        if (topic.pending!.status == DraftStatus.draft)
                          TextButton(
                            onPressed: () => _run(
                              context,
                              () => controller.queueDraft(topic.pending!.id),
                            ),
                            child: const Text('Queue Topic commit'),
                          ),
                        if (topic.pending!.status != DraftStatus.conflict &&
                            {
                              'create',
                              'update',
                            }.contains(topic.pending!.action))
                          TextButton(
                            onPressed: () =>
                                _nameDialog(context, controller, topic: topic),
                            child: const Text('Edit pending name'),
                          ),
                        TextButton(
                          onPressed: () => _run(
                            context,
                            () => controller.discardDraft(topic.pending!.id),
                          ),
                          child: const Text('Discard Topic change'),
                        ),
                      ],
                    ),
                  ],
                  if (owner && topic.pending == null)
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        if ({'active', 'hidden'}.contains(topic.state) &&
                            topic.revision > 0)
                          TextButton(
                            onPressed: controller.phase == DatasetPhase.ready
                                ? () => showPublicationReview(
                                    context,
                                    controller,
                                    'topic',
                                    topic.id,
                                  )
                                : null,
                            child: const Text('Review publication'),
                          ),
                        if ({'active', 'hidden'}.contains(topic.state))
                          TextButton(
                            onPressed: () =>
                                _nameDialog(context, controller, topic: topic),
                            child: const Text('Rename Topic'),
                          ),
                        if (topic.state == 'active')
                          TextButton(
                            onPressed: () => _run(
                              context,
                              () => controller.hideTopic(
                                topic.id,
                                expectedRevision: topic.revision,
                              ),
                            ),
                            child: const Text('Hide Topic'),
                          ),
                        if ({'active', 'hidden'}.contains(topic.state))
                          TextButton(
                            onPressed: () => _confirm(
                              context,
                              controller,
                              topic: topic,
                              restore: false,
                            ),
                            child: const Text('Delete Topic'),
                          ),
                        if (topic.state == 'deleted')
                          TextButton(
                            onPressed: () => _confirm(
                              context,
                              controller,
                              topic: topic,
                              restore: true,
                            ),
                            child: const Text('Restore Topic'),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

String _status(DraftStatus status) => switch (status) {
  DraftStatus.draft => 'Draft — saved locally',
  DraftStatus.unsent => 'Unsent commit — queued locally',
  DraftStatus.conflict => 'Conflict — review before queueing',
};
String _actionLabel(String action) => switch (action) {
  'create' => 'Create Topic',
  'update' => 'Rename Topic',
  'hide' => 'Hide Topic',
  'softDelete' => 'Delete Topic',
  'restore' => 'Restore Topic',
  _ => action,
};

String topicFailureMessage(Object error) {
  final code = error is DatasetStorageFailure ? error.code : '';
  return switch (code) {
    'forbidden' || 'storage-closed' => 'This workspace no longer permits that action. Check access before retrying.',
    'topic-pending-change' => 'This Topic already has a different pending change. Discard it or complete its commit before another action.',
    'topic-has-pending-children' => 'Local Pack or Card changes depend on this Topic. Discard or reclassify them before deleting the Topic.',
    'invalid-topic-state' || 'topic-not-eligible' => 'This Topic is no longer eligible for that action. Refresh the working dataset.',
    'draft-conflict' || 'storage-conflict' => 'This change conflicts with newer data. Refresh and review before queueing it.',
    'invalid-draft' => 'Enter a valid, nonempty Topic name.',
    'quota-exceeded' => 'Browser storage is full. Your last saved data is retained; free storage and retry.',
    _ => 'Could not save locally. Your last saved data is retained; check browser storage and retry.',
  };
}

Future<void> _run(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(topicFailureMessage(error))));
    }
  }
}

Future<void> _nameDialog(
  BuildContext context,
  DatasetController controller, {
  TopicTaxonomy? topic,
}) => showDialog<void>(
  context: context,
  builder: (_) => _TopicDialog(controller: controller, topic: topic),
);
Future<void> _confirm(
  BuildContext context,
  DatasetController controller, {
  required TopicTaxonomy topic,
  required bool restore,
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      _TopicDialog(controller: controller, topic: topic, restore: restore),
);

/// Every modal is bound to the opening account; role loss clears its inputs.
class _TopicDialog extends StatefulWidget {
  const _TopicDialog({required this.controller, this.topic, this.restore});
  final DatasetController controller;
  final TopicTaxonomy? topic;
  final bool? restore;
  @override
  State<_TopicDialog> createState() => _TopicDialogState();
}

class _TopicDialogState extends State<_TopicDialog> {
  late final String? _scope;
  late final _name = TextEditingController(text: widget.topic?.name ?? '');
  bool _saving = false;
  bool _closed = false;
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
    widget.controller.removeListener(_changed);
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (widget.restore == null && _name.text.trim().isEmpty) {
      setState(() => _error = 'Enter a Topic name.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (widget.restore == true) {
        await widget.controller.restoreTopic(
          widget.topic!.id,
          expectedRevision: widget.topic!.revision,
        );
      } else if (widget.restore == false) {
        await widget.controller.deleteTopic(
          widget.topic!.id,
          expectedRevision: widget.topic!.revision,
        );
      } else if (widget.topic == null) {
        await widget.controller.createTopic(_name.text.trim());
      } else {
        await widget.controller.renameTopic(
          widget.topic!.id,
          _name.text.trim(),
          expectedRevision: widget.topic!.revision,
        );
      }
      if (mounted && !_closed) Navigator.of(context).pop();
    } catch (error) {
      if (mounted && !_closed) {
        setState(() {
          _saving = false;
          _error = topicFailureMessage(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_closed) return const SizedBox.shrink();
    final title = widget.restore == true
        ? 'Restore Topic'
        : widget.restore == false
        ? 'Delete Topic'
        : widget.topic == null
        ? 'New Topic'
        : 'Rename Topic';
    final save = widget.restore == true
        ? 'Save restoration locally'
        : widget.restore == false
        ? 'Save deletion locally'
        : 'Save Topic locally';
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.restore == null)
                TextField(
                  controller: _name,
                  enabled: !_saving,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Topic name'),
                  onSubmitted: (_) {
                    if (!_saving) _save();
                  },
                )
              else
                Text(
                  widget.restore == true
                      ? 'Restore “${widget.topic!.name}” into hidden state. Only this Topic is restored; its Packs and Cards remain unchanged. This saves a pending local restoration and does not publish anything.'
                      : 'Delete “${widget.topic!.name}”? Committing its soft deletion will also delete the contained Packs and Cards. The Topic identity and relationships are retained. This saves a pending local deletion; no server data changes yet.',
                ),
              if (widget.restore == null) ...[
                const SizedBox(height: 12),
                const Text(
                  'Save locally first, then queue the Topic commit explicitly. No server write happens here.',
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Semantics(liveRegion: true, child: Text(_error!)),
              ],
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
          child: Text(_saving ? 'Saving locally…' : save),
        ),
      ],
    );
  }
}
