import 'dart:async';

import 'package:flutter/material.dart';

import '../data/bulk_card_import.dart';
import '../data/card_image_picker.dart';
import '../data/dataset_controller.dart';
import 'card_messages.dart';
import 'image_preparation_page.dart' show imagePreparationMessage;

class BulkCardImportPage extends StatefulWidget {
  const BulkCardImportPage({
    super.key,
    required this.controller,
    required this.packId,
    this.pickSources,
    this.onClose,
  });

  final DatasetController controller;
  final String packId;
  final Future<List<ImagePreparationSource>> Function()? pickSources;
  final VoidCallback? onClose;

  @override
  State<BulkCardImportPage> createState() => _BulkCardImportPageState();
}

class _BulkCardImportPageState extends State<BulkCardImportPage> {
  late final String? _scope;
  final _items = <BulkImportItem>[];
  final _nameControllers = <String, TextEditingController>{};
  final _hashes = <String>{};
  ImagePreparationCancellation? _prepCancellation;
  Completer<void>? _commitCancellation;
  bool _preparing = false;
  bool _committing = false;
  bool _closed = false;
  String? _error;
  String? _successMessage;
  BulkImportProgress? _progress;
  int _prepIndex = 0;
  int _prepTotal = 0;
  String? _prepFilename;

  bool get _busy => _preparing || _committing;
  bool get _allowed =>
      widget.controller.scope?.namespace == _scope &&
      widget.controller.eligibleCardPacks.any((p) => p.id == widget.packId);

  @override
  void initState() {
    super.initState();
    _scope = widget.controller.scope?.namespace;
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (!mounted || _closed) return;
    if (widget.controller.scope?.namespace != _scope) {
      _close();
    } else if (_busy && !_allowed) {
      _cancel();
      setState(
        () => _error = 'This Pack is no longer eligible for Card import.',
      );
    }
  }

  void _cancel() {
    _prepCancellation?.cancel();
    if (_commitCancellation != null && !_commitCancellation!.isCompleted) {
      _commitCancellation!.complete();
    }
    if (mounted) {
      setState(() {
        _preparing = false;
        _committing = false;
        _progress = null;
      });
    }
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _cancel();
    _clearControllers();
    _items.clear();
    _hashes.clear();
    if (mounted) {
      setState(() {});
      widget.onClose?.call();
    }
  }

  void _clearControllers() {
    for (final controller in _nameControllers.values) {
      controller.dispose();
    }
    _nameControllers.clear();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _prepCancellation?.cancel();
    if (_commitCancellation != null && !_commitCancellation!.isCompleted) {
      _commitCancellation!.complete();
    }
    _clearControllers();
    super.dispose();
  }

  Future<void> _pickAndPrepare() async {
    if (_busy || !_allowed || _closed) return;
    final cancellation = ImagePreparationCancellation();
    _prepCancellation = cancellation;
    setState(() {
      _preparing = true;
      _error = null;
      _successMessage = null;
      _prepIndex = 0;
      _prepTotal = 0;
      _prepFilename = null;
    });

    bool current() =>
        mounted &&
        !_closed &&
        identical(_prepCancellation, cancellation) &&
        !cancellation.isCancelled &&
        _allowed;

    List<ImagePreparationSource> sources = [];
    try {
      sources = await (widget.pickSources ?? pickImageSources)();
      if (!current()) {
        for (final source in sources) {
          source.dispose();
        }
        return;
      }
      if (sources.length > 500) {
        for (final source in sources) {
          source.dispose();
        }
        throw const ImagePreparationFailure(
          'batch-limit',
          'Select at most 500 images in one batch.',
        );
      }
      setState(() => _prepTotal = sources.length);

      // Collect existing card hashes for duplicate detection
      final existingHashes = <String>{};
      for (final card in widget.controller.cards) {
        if (card.packId == widget.packId && card.imageReference != null) {
          final ref = card.imageReference!;
          if (ref.startsWith('objects/') && ref.length >= 72) {
            existingHashes.add(ref.substring(8, 72));
          }
        }
      }

      for (var i = 0; i < sources.length; i++) {
        if (!current()) break;
        final source = sources[i];
        setState(() {
          _prepIndex = i + 1;
          _prepFilename = source.filename;
        });
        try {
          final image = await source.prepare(cancellation: cancellation);
          if (!current()) break;
          final info = image.preparation;
          if (info == null) {
            throw const ImagePreparationFailure(
              'invalid-output',
              'The prepared image could not be validated.',
            );
          }
          final isDuplicate =
              !_hashes.add(info.sha256) || existingHashes.contains(info.sha256);
          final cardId = widget.controller.newCardId();
          final item = BulkImportItem(
            id: cardId,
            sourceFilename: source.filename,
            name: image.suggestedName,
            difficulty: 2,
            image: image,
            isDuplicate: isDuplicate,
          );
          final controller = TextEditingController(text: item.name);
          _nameControllers[cardId] = controller;
          setState(() => _items.add(item));
        } catch (error) {
          if (!current()) break;
          setState(
            () => _error =
                'Failed on ${source.filename}: ${imagePreparationMessage(error)}',
          );
        } finally {
          source.dispose();
        }
        await Future<void>.delayed(Duration.zero);
      }
    } catch (error) {
      if (current()) setState(() => _error = imagePreparationMessage(error));
    } finally {
      for (final s in sources) {
        s.dispose();
      }
      if (identical(_prepCancellation, cancellation)) {
        if (mounted && !_closed) {
          setState(() {
            _preparing = false;
            _prepFilename = null;
          });
        }
      }
    }
  }

  Future<void> _saveAsDrafts() async {
    if (_busy || !_allowed || _closed || _items.isEmpty) return;
    setState(() {
      _error = null;
      _successMessage = null;
    });
    try {
      await widget.controller.saveBulkCardDrafts(
        packId: widget.packId,
        items: _items,
      );
      if (mounted) {
        setState(() {
          _successMessage =
              'Saved ${_items.where((i) => i.isValid).length} Card drafts locally. They will survive browser reload.';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = cardFailureMessage(error));
    }
  }

  Future<void> _commitAll() async {
    if (_busy || !_allowed || _closed || _items.isEmpty) return;
    final validItems = _items.where((i) => i.isValid).toList();
    if (validItems.isEmpty) {
      setState(
        () => _error =
            'No valid Cards to commit. Review card names and difficulties.',
      );
      return;
    }
    final cancellation = Completer<void>();
    _commitCancellation = cancellation;
    setState(() {
      _committing = true;
      _error = null;
      _successMessage = null;
      _progress = null;
    });

    try {
      final result = await widget.controller.importAndCommitBulkCards(
        packId: widget.packId,
        items: validItems,
        onProgress: (progress) {
          if (mounted &&
              !_closed &&
              identical(_commitCancellation, cancellation)) {
            setState(() => _progress = progress);
          }
        },
        cancelled: cancellation.future,
      );
      if (mounted && !_closed) {
        setState(() {
          _successMessage =
              'Committed ${result.committedCount} Cards in ${result.batchCount} batch(es) at Pack revision ${result.finalRevision}.';
          // Remove committed items from review list
          final committedIds = validItems.map((i) => i.id).toSet();
          _items.removeWhere((i) => committedIds.contains(i.id));
          for (final id in committedIds) {
            _nameControllers.remove(id)?.dispose();
          }
        });
      }
    } catch (error) {
      if (mounted && !_closed) {
        setState(() => _error = cardFailureMessage(error));
      }
    } finally {
      if (identical(_commitCancellation, cancellation)) {
        if (mounted && !_closed) {
          setState(() {
            _committing = false;
            _progress = null;
          });
        }
      }
    }
  }

  void _removeItem(int index) {
    if (_busy || index < 0 || index >= _items.length) return;
    final item = _items.removeAt(index);
    _hashes.remove(item.image.preparation?.sha256);
    _nameControllers.remove(item.id)?.dispose();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_closed || widget.controller.scope?.namespace != _scope) {
      return const SizedBox.shrink();
    }

    final readyCount = _items.where((i) => i.isValid && !i.isDuplicate).length;
    final validCount = _items.where((i) => i.isValid).length;
    final duplicateCount = _items.where((i) => i.isDuplicate).length;
    final invalidCount = _items.where((i) => !i.isValid).length;
    final totalBytes = _items.fold<int>(
      0,
      (sum, i) => sum + i.image.bytes.length,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bulk import Cards'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Close import',
          onPressed: _busy ? null : _close,
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isDesktop = constraints.maxWidth >= 680;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Pack: ${widget.packId}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Card(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'Selected in-memory files cannot be recovered across browser reload. Save as local drafts or commit your import to retain them.',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      onPressed: _busy || !_allowed ? null : _pickAndPrepare,
                      child: Text(
                        _items.isEmpty ? 'Select images' : 'Select more images',
                      ),
                    ),
                    if (_items.isNotEmpty) ...[
                      OutlinedButton(
                        onPressed: _busy || !_allowed ? null : _saveAsDrafts,
                        child: const Text('Save as local drafts'),
                      ),
                      FilledButton.tonal(
                        onPressed: _busy || !_allowed || validCount == 0
                            ? null
                            : _commitAll,
                        child: const Text('Upload & Commit Cards'),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () {
                                _clearControllers();
                                _items.clear();
                                _hashes.clear();
                                setState(() {});
                              },
                        child: const Text('Clear all'),
                      ),
                    ],
                    if (_busy)
                      OutlinedButton(
                        onPressed: _cancel,
                        child: const Text('Cancel operation'),
                      ),
                  ],
                ),
                if (_preparing) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    liveRegion: true,
                    child: Text('Preparing image $_prepIndex of $_prepTotal'),
                  ),
                  if (_prepFilename != null) Text(_prepFilename!),
                  LinearProgressIndicator(
                    value: _prepTotal > 0
                        ? (_prepIndex / _prepTotal).clamp(0, 1)
                        : 0,
                  ),
                ],
                if (_committing && _progress != null) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _progress!.stage == 'uploading'
                          ? 'Uploading image ${_progress!.current} of ${_progress!.total}${_progress!.detail != null ? ' (${_progress!.detail})' : ''}'
                          : 'Committing batch ${_progress!.current} of ${_progress!.total}',
                    ),
                  ),
                  LinearProgressIndicator(value: _progress!.fraction),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
                if (_successMessage != null) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _successMessage!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ],
                if (_items.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    '$readyCount ready · $duplicateCount duplicates · $invalidCount invalid',
                  ),
                  if (totalBytes > 10 * 1024 * 1024)
                    const Text(
                      'Prepared images exceed the approximate 10 MiB Pack target. Review image quality and size before import.',
                      style: TextStyle(color: Colors.orange),
                    ),
                  const SizedBox(height: 12),
                  if (isDesktop) _buildDesktopTable() else _buildNarrowList(),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildDesktopTable() {
    return Table(
      columnWidths: const {
        0: FixedColumnWidth(56),
        1: FlexColumnWidth(1.2),
        2: FlexColumnWidth(2.0),
        3: FixedColumnWidth(130),
        4: FixedColumnWidth(100),
        5: FixedColumnWidth(48),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        const TableRow(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(width: 1, color: Colors.grey)),
          ),
          children: [
            Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Preview',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Source',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Card Name',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Difficulty',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Status',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Padding(padding: EdgeInsets.all(8), child: Text('')),
          ],
        ),
        for (var i = 0; i < _items.length; i++) _buildTableRow(i),
      ],
    );
  }

  TableRow _buildTableRow(int index) {
    final item = _items[index];
    final controller = _nameControllers[item.id] ??= TextEditingController(
      text: item.name,
    );
    return TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.all(4),
          child: Semantics(
            label: 'Preview for ${item.name}',
            image: true,
            child: Image.memory(
              item.image.bytes,
              width: 48,
              height: 48,
              fit: BoxFit.cover,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(4),
          child: Text(item.sourceFilename, overflow: TextOverflow.ellipsis),
        ),
        Padding(
          padding: const EdgeInsets.all(4),
          child: TextField(
            controller: controller,
            decoration: InputDecoration(
              isDense: true,
              errorText: item.name.trim().isEmpty ? 'Required' : null,
            ),
            textInputAction: TextInputAction.next,
            onChanged: (val) {
              item.name = val;
              setState(() {});
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(4),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: item.difficulty,
              isDense: true,
              isExpanded: true,
              items: const [
                DropdownMenuItem(value: 1, child: Text('1 (Easy)')),
                DropdownMenuItem(value: 2, child: Text('2 (Med)')),
                DropdownMenuItem(value: 3, child: Text('3 (Hard)')),
              ],
              onChanged: _busy
                  ? null
                  : (val) {
                      if (val != null) {
                        setState(() => item.difficulty = val);
                      }
                    },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(4),
          child: _buildStatusBadge(item),
        ),
        Padding(
          padding: const EdgeInsets.all(4),
          child: IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            tooltip: 'Remove ${item.name}',
            onPressed: _busy ? null : () => _removeItem(index),
          ),
        ),
      ],
    );
  }

  Widget _buildNarrowList() {
    return Column(
      children: [for (var i = 0; i < _items.length; i++) _buildNarrowCard(i)],
    );
  }

  Widget _buildNarrowCard(int index) {
    final item = _items[index];
    final controller = _nameControllers[item.id] ??= TextEditingController(
      text: item.name,
    );
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Semantics(
                  label: 'Preview for ${item.name}',
                  image: true,
                  child: Image.memory(
                    item.image.bytes,
                    width: 48,
                    height: 48,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.sourceFilename,
                        overflow: TextOverflow.ellipsis,
                      ),
                      _buildStatusBadge(item),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Remove ${item.name}',
                  onPressed: _busy ? null : () => _removeItem(index),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: 'Card Name',
                isDense: true,
                errorText: item.name.trim().isEmpty ? 'Required' : null,
              ),
              textInputAction: TextInputAction.next,
              onChanged: (val) {
                item.name = val;
                setState(() {});
              },
            ),
            const SizedBox(height: 8),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                const Text('Difficulty:'),
                DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: item.difficulty,
                    isDense: true,
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('1 (Easy)')),
                      DropdownMenuItem(value: 2, child: Text('2 (Medium)')),
                      DropdownMenuItem(value: 3, child: Text('3 (Hard)')),
                    ],
                    onChanged: _busy
                        ? null
                        : (val) {
                            if (val != null) {
                              setState(() => item.difficulty = val);
                            }
                          },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBadge(BulkImportItem item) {
    if (item.isDuplicate) {
      return const Text(
        'Duplicate',
        style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
      );
    }
    if (!item.isValid) {
      return const Text(
        'Invalid',
        style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
      );
    }
    if (item.uploadedImage != null) {
      return const Text('Uploaded', style: TextStyle(color: Colors.green));
    }
    return const Text('Ready');
  }
}

Future<void> showBulkCardImport(
  BuildContext context,
  DatasetController controller,
  String packId, {
  Future<List<ImagePreparationSource>> Function()? pickSources,
}) => showDialog<void>(
  context: context,
  builder: (dialogContext) => Dialog.fullscreen(
    child: SafeArea(
      child: BulkCardImportPage(
        controller: controller,
        packId: packId,
        pickSources: pickSources,
        onClose: () => Navigator.of(dialogContext).pop(),
      ),
    ),
  ),
);
