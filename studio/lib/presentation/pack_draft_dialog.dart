import 'dart:async';

import 'package:flutter/material.dart';

import '../data/dataset_controller.dart';
import '../data/studio_dataset.dart';
import '../data/pack_summary.dart';
import 'packs_page.dart' show packFailureMessage;
import 'topic_picker.dart';

/// A classification entry point independent of Topic administration.
class PackDraftDialog extends StatefulWidget {
  const PackDraftDialog({
    super.key,
    required this.controller,
    this.draft,
    this.pack,
  });
  final DatasetController controller;
  final LocalDraft? draft;
  final PackSummary? pack;
  @override
  State<PackDraftDialog> createState() => _PackDraftDialogState();
}

class _PackDraftDialogState extends State<PackDraftDialog> {
  late final _name = TextEditingController(
    text: widget.pack?.name ?? widget.draft?.value['name'] as String? ?? '',
  );
  late final String? _scope;
  String? _topicId;
  String? _error;
  bool _saving = false;
  bool _closed = false;
  @override
  void initState() {
    super.initState();
    _scope = widget.controller.scope?.namespace;
    _topicId =
        widget.pack?.topicId ?? widget.draft?.value['topicId'] as String?;
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (_closed || widget.controller.scope?.namespace == _scope) return;
    _closed = true;
    _name.clear();
    _topicId = null;
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
    if (_name.text.trim().isEmpty || _topicId == null) {
      setState(
        () => _error = 'Enter a Pack name and choose an eligible Topic.',
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (widget.pack != null && widget.pack!.revision > 0) {
        await widget.controller.updatePack(
          widget.pack!.id,
          name: _name.text.trim(),
          topicId: _topicId!,
          expectedRevision: widget.pack!.revision,
        );
      } else if ((widget.draft ?? widget.pack?.pending) == null) {
        await widget.controller.createPackDraft(
          name: _name.text.trim(),
          topicId: _topicId!,
        );
      } else {
        await widget.controller.updatePackDraft(
          (widget.draft ?? widget.pack!.pending)!.id,
          name: _name.text.trim(),
          topicId: _topicId!,
        );
      }
      if (mounted && !_closed) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted || _closed) return;
      setState(() {
        _saving = false;
        _error = packFailureMessage(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) => _closed
      ? const SizedBox.shrink()
      : AlertDialog(
          title: Text(
            widget.draft == null && widget.pack == null
                ? 'New Pack draft'
                : 'Edit Pack draft',
          ),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _name,
                    enabled: !_saving,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Pack name'),
                    onSubmitted: (_) {
                      if (!_saving) _save();
                    },
                  ),
                  const SizedBox(height: 12),
                  if (widget.pack != null && widget.pack!.revision > 0)
                    Text(
                      'Topic: ${widget.pack!.topicId} (fixed for synchronized Packs)',
                    )
                  else
                    IgnorePointer(
                      ignoring: _saving,
                      child: TopicPicker(
                        controller: widget.controller,
                        value: _topicId,
                        onChanged: (value) {
                          if (mounted && !_closed) {
                            setState(() => _topicId = value);
                          }
                        },
                      ),
                    ),
                  const SizedBox(height: 12),
                  const Text(
                    'This saves a local Pack draft with one Topic. It does not upload or publish content.',
                  ),
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
              child: Text(
                _saving ? 'Saving locally…' : 'Save Pack draft locally',
              ),
            ),
          ],
        );
}
