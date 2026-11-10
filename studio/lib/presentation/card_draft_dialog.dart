import 'dart:async';

import 'package:flutter/material.dart';

import '../data/card_image.dart';
import '../data/card_image_picker.dart';
import '../data/card_summary.dart';
import '../data/dataset_controller.dart';
import 'card_messages.dart';

class CardDraftDialog extends StatefulWidget {
  const CardDraftDialog({
    super.key,
    required this.controller,
    required this.packId,
    this.card,
    this.pickImage,
  });
  final DatasetController controller;
  final String packId;
  final CardSummary? card;
  final Future<CardImage?> Function()? pickImage;
  @override
  State<CardDraftDialog> createState() => _CardDraftDialogState();
}

class _CardDraftDialogState extends State<CardDraftDialog> {
  late final _name = TextEditingController(text: widget.card?.name ?? '');
  late final String? _scope;
  late int _difficulty = widget.card?.difficulty ?? 1;
  late CardImage? _image = widget.card?.localImage;
  bool _closed = false;
  bool _saving = false;
  bool _picking = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _scope = widget.controller.scope?.namespace;
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (_closed || _scope == widget.controller.scope?.namespace) return;
    _closed = true;
    _name.clear();
    _image = null;
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
    _image = null;
    super.dispose();
  }

  Future<void> _pick() async {
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final image = await (widget.pickImage ?? pickCardImage)();
      if (!mounted || _closed) return;
      setState(() {
        if (image != null) {
          _image = image;
          if (_name.text.trim().isEmpty) _name.text = image.suggestedName;
        }
      });
    } catch (_) {
      if (mounted && !_closed) {
        setState(
          () => _error = 'Could not select that image. Choose a JPEG, PNG or WebP image up to 5 MiB. Your previous image is retained.',
        );
      }
    } finally {
      if (mounted && !_closed) setState(() => _picking = false);
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty ||
        _image == null && (widget.card?.imageReference ?? '').isEmpty) {
      setState(() => _error = 'Enter a Card name and select an image.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final card = widget.card;
      if (card == null) {
        await widget.controller.createCardDraft(
          packId: widget.packId,
          name: _name.text.trim(),
          difficulty: _difficulty,
          image: _image,
        );
      } else if (card.revision == 0) {
        await widget.controller.updateCardDraft(
          card.pending!.id,
          packId: widget.packId,
          name: _name.text.trim(),
          difficulty: _difficulty,
          image: _image,
        );
      } else {
        await widget.controller.updateCard(
          card.id,
          name: _name.text.trim(),
          difficulty: _difficulty,
          image: _image,
          expectedRevision: card.revision,
        );
      }
      if (mounted && !_closed) Navigator.of(context).pop();
    } catch (error) {
      if (mounted && !_closed) {
        setState(() {
          _saving = false;
          _error = cardFailureMessage(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_closed) return const SizedBox.shrink();
    final disabled = _saving || _picking;
    return AlertDialog(
      title: Text(widget.card == null ? 'New Card' : 'Edit Card'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Pack: ${widget.packId}'),
              if (widget.card != null) Text('Card ID: ${widget.card!.id}'),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                autofocus: true,
                enabled: !disabled,
                decoration: const InputDecoration(labelText: 'Card name'),
                onSubmitted: (_) {
                  if (!disabled) _save();
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: _difficulty,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Difficulty'),
                items: const [
                  DropdownMenuItem(value: 1, child: Text('1 — Easy')),
                  DropdownMenuItem(value: 2, child: Text('2 — Medium')),
                  DropdownMenuItem(value: 3, child: Text('3 — Hard')),
                ],
                onChanged: disabled
                    ? null
                    : (value) => setState(() => _difficulty = value ?? 1),
              ),
              const SizedBox(height: 12),
              if (_image != null) ...[
                Semantics(
                  label: 'Selected image preview',
                  image: true,
                  child: Image.memory(
                    _image!.bytes,
                    height: 180,
                    fit: BoxFit.contain,
                    cacheWidth: 400,
                    errorBuilder: (_, _, _) => const SizedBox(
                      height: 100,
                      child: Center(
                        child: Text(
                          'Image preview unavailable. Choose another image.',
                        ),
                      ),
                    ),
                  ),
                ),
                Text(_image!.filename),
                const Text(
                  'Selected image is saved locally with this draft. It has not been uploaded.',
                ),
              ] else
                Text(
                  widget.card?.imageReference == null
                      ? 'No image selected.'
                      : 'Existing private image retained. Preview unavailable.',
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: disabled ? null : _pick,
                icon: const Icon(Icons.image_outlined),
                label: Text(
                  _picking
                      ? 'Selecting image…'
                      : _image != null || widget.card?.imageReference != null
                      ? 'Replace image'
                      : 'Select image',
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Save locally, review the Card, then queue a commit explicitly. Nothing is uploaded or published here.',
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
          onPressed: disabled ? null : _save,
          child: Text(_saving ? 'Saving locally…' : 'Save Card locally'),
        ),
      ],
    );
  }
}
