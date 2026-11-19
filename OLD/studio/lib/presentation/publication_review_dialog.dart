import 'dart:async';

import 'package:flutter/material.dart';

import '../data/dataset_controller.dart';
import '../data/dataset_store.dart';
import '../data/publication_api.dart';

Future<void> showPublicationReview(
  BuildContext context,
  DatasetController controller,
  String resourceType,
  String id,
) => showDialog<void>(
  context: context,
  builder: (_) => PublicationReviewDialog(
    controller: controller,
    resourceType: resourceType,
    id: id,
  ),
);

/// A server review is separate from local editing and from operator release.
class PublicationReviewDialog extends StatefulWidget {
  const PublicationReviewDialog({
    super.key,
    required this.controller,
    required this.resourceType,
    required this.id,
  });
  final DatasetController controller;
  final String resourceType;
  final String id;
  @override
  State<PublicationReviewDialog> createState() =>
      _PublicationReviewDialogState();
}

class _PublicationReviewDialogState extends State<PublicationReviewDialog> {
  late final String? _scope;
  final _evidence = TextEditingController();
  PublicationReview? _review;
  bool _busy = true;
  bool _closed = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _scope = widget.controller.scope?.namespace;
    widget.controller.addListener(_changed);
    unawaited(_run());
  }

  void _changed() {
    if (_closed) return;
    if (widget.controller.scope?.namespace != _scope ||
        widget.controller.phase != DatasetPhase.ready) {
      _closed = true;
      _review = null;
      _evidence.clear();
      if (mounted) {
        setState(() {});
        scheduleMicrotask(() {
          if (mounted) Navigator.of(context).pop();
        });
      }
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _evidence.dispose();
    super.dispose();
  }

  Future<void> _run([String? action]) async {
    if (action == 'approve-rights' && _evidence.text.trim().isEmpty) {
      setState(() => _error = 'Enter the rights evidence reference.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final review = await widget.controller.reviewPublication(
        widget.resourceType,
        widget.id,
        action: action,
        expected: _review,
        evidence: action == 'approve-rights' ? _evidence.text.trim() : null,
      );
      if (mounted && !_closed) setState(() => _review = review);
    } catch (error) {
      if (mounted && !_closed) {
        setState(() {
          _error = publicationFailureMessage(error);
          // A failed/stale action must be reviewed again before another write.
          _review = null;
        });
      }
    } finally {
      if (mounted && !_closed) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_closed) return const SizedBox.shrink();
    final review = _review;
    final owner = widget.controller.scope?.role == 'owner_admin';
    final pack = widget.resourceType == 'pack';
    return AlertDialog(
      title: Text('${pack ? 'Pack' : 'Topic'} publication review'),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Review the committed server content. Local changes must be '
                'committed or discarded before publication.',
              ),
              if (_busy) const LinearProgressIndicator(),
              if (review != null) ...[
                const SizedBox(height: 12),
                Text('${review.id} · revision ${review.revision}'),
                Text(
                  review.published
                      ? 'Public revision: ${review.publishedRevision ?? review.revision}'
                      : 'Not public',
                ),
                if (review.pendingRequestId != null ||
                    review.status == 'pending_operator')
                  const Text(
                    'Release requested — awaiting trusted operator validation '
                    'and signing. This request has not published this revision.',
                  ),
                if (review.status == 'unpublished')
                  const Text(
                    'Unpublished. Retained revisions remain recoverable. '
                    'Downloaded offline copies are not removed.',
                  ),
                if (pack) ...[
                  Text('${review.eligibleCardCount} eligible Cards'),
                  Text(
                    review.rightsApproved
                        ? 'Rights approved for the reviewed images'
                        : 'Rights approval required',
                  ),
                  for (final card in review.cards)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        '${card['name']} · difficulty ${card['difficulty']}\n'
                        '${card['id']} · ${card['imageReference']}',
                      ),
                    ),
                ],
                if (review.publishedRevision == null)
                  Text(
                    review.initialApproved
                        ? 'Initial publication approved by Owner'
                        : 'Initial Owner approval required',
                  ),
                for (final error in review.errors) Text('Validation: $error'),
                if (owner && pack) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _evidence,
                    enabled: !_busy,
                    maxLength: 1000,
                    decoration: const InputDecoration(
                      labelText: 'Rights evidence reference',
                      helperText: 'Reference the reviewed permission or license record.',
                    ),
                  ),
                ],
              ],
              if (_error != null)
                Semantics(liveRegion: true, child: Text(_error!)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed: _busy ? null : () => _run(),
                    child: const Text('Refresh review'),
                  ),
                  if (review != null) ...[
                    TextButton(
                      onPressed: _busy ? null : () => _run('validate'),
                      child: const Text('Validate'),
                    ),
                    if (owner && pack)
                      TextButton(
                        onPressed: _busy ? null : () => _run('approve-rights'),
                        child: const Text('Approve reviewed rights'),
                      ),
                    if (owner && !review.initialApproved)
                      TextButton(
                        onPressed: _busy ? null : () => _run('approve'),
                        child: Text(
                          review.publishedRevision == null
                              ? 'Approve initial publication'
                              : 'Approve publication',
                        ),
                      ),
                    FilledButton(
                      onPressed:
                          _busy ||
                              review.errors.isNotEmpty ||
                              review.pendingRequestId != null ||
                              (review.publishedRevision == null &&
                                  !review.initialApproved) ||
                              ((!pack || review.state == 'hidden') &&
                                  !review.initialApproved) ||
                              (!owner && review.state == 'hidden') ||
                              (pack && !review.rightsApproved)
                          ? null
                          : () => _run('publish'),
                      child: Text(
                        pack ? 'Request validated release' : 'Publish Topic',
                      ),
                    ),
                    if (review.published || review.pendingRequestId != null)
                      OutlinedButton(
                        onPressed: _busy ? null : () => _run('unpublish'),
                        child: const Text('Unpublish'),
                      ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

String publicationFailureMessage(Object error) {
  final code = error is DatasetStorageFailure ? error.code : '';
  return switch (code) {
    'publication-pending-changes' => 'Commit or discard the local changes in this container before reviewing publication.',
    'publication-offline' =>
      'Publication requires an online authorized workspace.',
    'publication-conflict' => 'The reviewed revision changed. Refresh the review before approving or publishing.',
    'publication-invalid' => 'This content failed publication validation. Refresh the review to inspect the blockers.',
    'forbidden' ||
    'session-expired' ||
    'cancelled' => 'Access changed. Check your account before continuing.',
    _ => 'Publication review is unavailable. Refresh the review and retry.',
  };
}
