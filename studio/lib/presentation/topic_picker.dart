import 'package:flutter/material.dart';

import '../data/dataset_controller.dart';

/// Classification uses only existing, account-permitted taxonomy records.
class TopicPicker extends StatefulWidget {
  const TopicPicker({
    super.key,
    required this.controller,
    required this.value,
    required this.onChanged,
  });
  final DatasetController controller;
  final String? value;
  final ValueChanged<String?> onChanged;
  @override
  State<TopicPicker> createState() => _TopicPickerState();
}

class _TopicPickerState extends State<TopicPicker> {
  final _search = TextEditingController();
  String? _scope;
  bool _invalidated = false;

  @override
  void initState() {
    super.initState();
    _scope = widget.controller.scope?.namespace;
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(TopicPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
    if (oldWidget.value != widget.value) _invalidated = false;
  }

  void _changed() {
    if (!mounted) return;
    if (_scope != widget.controller.scope?.namespace) {
      _scope = widget.controller.scope?.namespace;
      _search.clear();
      _clearSelection();
    }
    setState(() {});
    _invalidateSelection();
  }

  void _invalidateSelection() {
    final value = widget.value;
    if (value == null ||
        _invalidated ||
        widget.controller.eligibleTopics.any((topic) => topic.id == value)) {
      return;
    }
    _clearSelection();
  }

  void _clearSelection() {
    final value = widget.value;
    if (value == null) return;
    _invalidated = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.value == value) widget.onChanged(null);
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _invalidateSelection();
    final permitted = widget.controller.eligibleTopics;
    final selected = permitted.any((topic) => topic.id == widget.value)
        ? widget.value
        : null;
    final query = _search.text.trim().toLowerCase();
    final choices = permitted
        .where(
          (topic) =>
              topic.id == selected ||
              topic.name.toLowerCase().contains(query) ||
              topic.id.toLowerCase().contains(query),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _search,
          decoration: const InputDecoration(labelText: 'Find a Topic'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey(
            '${_scope ?? ''}:$selected:${choices.map((topic) => topic.id).join(',')}',
          ),
          initialValue: selected,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Topic'),
          items: [
            for (final topic in choices)
              DropdownMenuItem(
                value: topic.id,
                child: Tooltip(
                  message: '${topic.name} (${topic.state})',
                  child: Text(
                    '${topic.name}${topic.state == 'hidden' ? ' (hidden)' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
          onChanged: choices.isEmpty ? null : widget.onChanged,
        ),
        if (permitted.isEmpty) ...[
          const SizedBox(height: 8),
          const Text(
            'No existing eligible Topics are available. Refresh the permitted taxonomy before preparing a Pack.',
          ),
        ] else if (choices.isEmpty) ...[
          const SizedBox(height: 8),
          const Text('No Topics match this search.'),
        ],
        const SizedBox(height: 8),
        const Text(
          'Choose an existing active or hidden Topic. Deleted Topics and unsynchronized Topic drafts cannot be assigned.',
        ),
      ],
    );
  }
}
