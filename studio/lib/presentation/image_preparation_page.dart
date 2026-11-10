import 'dart:async';

import 'package:flutter/material.dart';

import '../data/card_image.dart';
import '../data/card_image_picker.dart';
import '../data/dataset_controller.dart';

class ImagePreparationPage extends StatefulWidget {
  const ImagePreparationPage({
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
  State<ImagePreparationPage> createState() => _ImagePreparationPageState();
}

class _PreparationResult {
  const _PreparationResult(this.filename, this.status, this.detail);
  final String filename;
  final String status;
  final String detail;
}

/// Batch review retains metadata and one preview, never a decoded image queue.
class _ImagePreparationPageState extends State<ImagePreparationPage> {
  late final String? _scope;
  ImagePreparationCancellation? _cancellation;
  List<ImagePreparationSource> _sources = [];
  final _results = <_PreparationResult>[];
  final _hashes = <String>{};
  CardImage? _preview;
  ImagePreparationProgress? _progress;
  String? _error;
  String? _filename;
  int _index = 0;
  int _total = 0;
  int _bytes = 0;
  bool _busy = false;
  bool _closed = false;
  bool get _allowed =>
      widget.controller.scope?.namespace == _scope &&
      widget.controller.eligibleCardPacks.any((p) => p.id == widget.packId);
  @override
  void initState() {
    super.initState();
    _scope = widget.controller.scope?.namespace;
    widget.controller.addListener(_changed);
  }

  void _releaseSources() {
    for (final source in _sources) {
      source.dispose();
    }
    _sources = [];
  }

  void _changed() {
    if (!mounted || _closed) return;
    if (widget.controller.scope?.namespace != _scope) {
      _close();
    } else if (_busy && !_allowed) {
      _cancel();
      setState(
        () => _error = 'This Pack is no longer eligible for image preparation.',
      );
    }
  }

  void _cancel() {
    _cancellation?.cancel();
    _releaseSources();
    if (mounted) {
      setState(() {
        _busy = false;
        _progress = null;
        _filename = null;
      });
    }
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _cancel();
    _preview = null;
    _results.clear();
    _hashes.clear();
    if (mounted) {
      setState(() {});
      widget.onClose?.call();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _cancellation?.cancel();
    _releaseSources();
    _preview = null;
    super.dispose();
  }

  Future<void> _start() async {
    if (_busy || !_allowed || _closed) return;
    final cancellation = ImagePreparationCancellation();
    _cancellation = cancellation;
    setState(() {
      _busy = true;
      _error = null;
      _results.clear();
      _hashes.clear();
      _preview = null;
      _index = 0;
      _total = 0;
      _bytes = 0;
    });
    bool current() =>
        mounted &&
        !_closed &&
        identical(_cancellation, cancellation) &&
        !cancellation.isCancelled &&
        _allowed;
    try {
      final sources = await (widget.pickSources ?? pickImageSources)();
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
      _sources = sources;
      setState(() => _total = sources.length);
      for (var i = 0; i < sources.length; i++) {
        if (!current()) break;
        final source = sources[i];
        setState(() {
          _index = i + 1;
          _filename = source.filename;
          _progress = null;
        });
        try {
          final image = await source.prepare(
            cancellation: cancellation,
            onProgress: (progress) {
              if (current()) setState(() => _progress = progress);
            },
          );
          if (!current()) break;
          final info = image.preparation;
          if (info == null) {
            throw const ImagePreparationFailure(
              'invalid-output',
              'The prepared image could not be validated.',
            );
          }
          final duplicate = !_hashes.add(info.sha256);
          final imageBytes = image.bytes.length;
          setState(() {
            if (!duplicate) {
              _preview = image;
              _bytes += imageBytes;
            }
            _results.add(
              _PreparationResult(
                source.filename,
                duplicate ? 'Duplicate' : 'Prepared',
                '${image.filename} · ${info.width} × ${info.height} · $imageBytes bytes${info.warnings.isEmpty ? '' : '\n${info.warnings.join('\n')}'}',
              ),
            );
          });
        } catch (error) {
          if (!current()) break;
          setState(
            () => _results.add(
              _PreparationResult(
                source.filename,
                'Failed',
                imagePreparationMessage(error),
              ),
            ),
          );
        } finally {
          source.dispose();
        }
        // Native image work runs in its worker; yield between every result too.
        await Future<void>.delayed(Duration.zero);
      }
    } catch (error) {
      if (current()) setState(() => _error = imagePreparationMessage(error));
    } finally {
      if (identical(_cancellation, cancellation)) {
        _releaseSources();
        if (mounted && !_closed) {
          setState(() {
            _busy = false;
            _progress = null;
            _filename = null;
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_closed || widget.controller.scope?.namespace != _scope) {
      return const SizedBox.shrink();
    }
    final prepared = _results.where((r) => r.status == 'Prepared').length;
    final duplicates = _results.where((r) => r.status == 'Duplicate').length;
    final failed = _results.where((r) => r.status == 'Failed').length;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Prepare images',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          Text('Pack: ${widget.packId}'),
          const SizedBox(height: 12),
          const Text(
            'Batch checks keep a summary and one preview. Use the Card editor to save a prepared image; bulk Card import is separate.',
          ),
          const Text(
            'JPEG, PNG and WebP · up to 500 files · one image at a time. Around 50 KiB per image and 10 MiB per Pack are review targets, not rejection limits.',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: _busy || !_allowed ? null : _start,
                child: const Text('Select images'),
              ),
              if (_busy)
                OutlinedButton(
                  onPressed: _cancel,
                  child: const Text('Cancel preparation'),
                ),
              TextButton(
                onPressed: _close,
                child: const Text('Close image preparation'),
              ),
            ],
          ),
          if (_busy) ...[
            Semantics(
              liveRegion: true,
              child: Text('Preparing image $_index of $_total'),
            ),
            if (_filename != null) Text(_filename!),
            Text(_progress?.stage ?? 'Waiting for image selection'),
            LinearProgressIndicator(
              value: _progress?.fraction.clamp(0, 1) ?? 0,
            ),
          ],
          if (_error != null) Semantics(liveRegion: true, child: Text(_error!)),
          const SizedBox(height: 12),
          Text('$prepared prepared · $duplicates duplicates · $failed failed'),
          if (_bytes > 10 * 1024 * 1024)
            const Text(
              'Prepared unique images exceed the approximate 10 MiB Pack target. Review image quality and size before import.',
            ),
          if (_preview != null) ...[
            Semantics(
              label: 'Current prepared image preview',
              image: true,
              child: Image.memory(
                _preview!.bytes,
                height: 160,
                fit: BoxFit.contain,
                cacheWidth: 320,
                errorBuilder: (_, _, _) =>
                    const Text('Prepared image preview unavailable.'),
              ),
            ),
            Text(_preview!.filename),
          ],
          const SizedBox(height: 12),
          SizedBox(
            height: 320,
            child: ListView.builder(
              itemCount: _results.length,
              itemBuilder: (_, index) {
                final result = _results[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(result.filename),
                      Text(result.status),
                      Text(result.detail),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

String imagePreparationMessage(Object error) => error is ImagePreparationFailure
    ? error.message
    : 'This image could not be prepared. Check its format, browser support and available memory, then retry.';

Future<void> showImagePreparation(
  BuildContext context,
  DatasetController controller,
  String packId,
) => showDialog<void>(
  context: context,
  builder: (dialogContext) => Dialog.fullscreen(
    child: SafeArea(
      child: SingleChildScrollView(
        child: ImagePreparationPage(
          controller: controller,
          packId: packId,
          onClose: () => Navigator.of(dialogContext).pop(),
        ),
      ),
    ),
  ),
);
