import 'dart:async';

import 'package:flutter/material.dart';

import '../data/card_summary.dart';
import '../data/dataset_controller.dart';
import '../data/studio_dataset.dart';
import 'card_draft_dialog.dart';
import 'card_messages.dart';

class CardsPage extends StatefulWidget {
  const CardsPage({super.key, required this.controller, this.initialPackId});
  final DatasetController controller;
  final String? initialPackId;
  @override
  State<CardsPage> createState() => _CardsPageState();
}

class _CardsPageState extends State<CardsPage> {
  final _search = TextEditingController();
  String? _packId;
  String? _scope;
  @override
  void initState() {
    super.initState();
    _scope = widget.controller.scope?.namespace;
    _packId = widget.initialPackId;
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(CardsPage oldWidget) {
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
      _packId = null;
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
    final packs = controller.packs;
    if (!packs.any((p) => p.id == _packId)) _packId = packs.firstOrNull?.id;
    final selected = packs.where((p) => p.id == _packId).firstOrNull;
    final eligible = controller.eligibleCardPacks.any((p) => p.id == _packId);
    final owner = controller.scope!.role == 'owner_admin';
    final query = _search.text.trim().toLowerCase();
    final cards = controller.cards
        .where(
          (card) =>
              card.packId == _packId &&
              (card.name.toLowerCase().contains(query) ||
                  card.id.toLowerCase().contains(query)),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Review Cards inside one Pack. Save locally and queue each commit explicitly.',
        ),
        const SizedBox(height: 12),
        if (packs.isEmpty)
          const Text('No authorized Packs are available for Card review.')
        else
          DropdownButtonFormField<String>(
            key: ValueKey('${controller.scope!.namespace}:$_packId'),
            initialValue: _packId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Pack'),
            items: [
              for (final pack in packs)
                DropdownMenuItem(
                  value: pack.id,
                  child: Text(
                    '${pack.name} · ${pack.id}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (value) => setState(() {
              _packId = value;
              _search.clear();
            }),
          ),
        if (selected != null) ...[
          const SizedBox(height: 12),
          Text('Pack: ${selected.name}'),
          if (owner)
            Text(
              'Pack creator: ${selected.createdByUid ?? 'Unassigned legacy draft'}',
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonal(
              onPressed: !eligible
                  ? null
                  : () => showDialog<void>(
                      context: context,
                      builder: (_) => CardDraftDialog(
                        controller: controller,
                        packId: _packId!,
                      ),
                    ),
              child: const Text('New Card'),
            ),
          ),
          if (!eligible)
            const Text(
              'This Pack is not currently eligible for Card authoring. Refresh or resolve its pending operation.',
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _search,
            decoration: const InputDecoration(
              labelText: 'Search Cards',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          if (cards.isEmpty) const Text('No Cards match this Pack view.'),
          for (final card in cards)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      card.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text('Card ID: ${card.id}'),
                    Text('Pack: ${card.packId}'),
                    Text('Difficulty: ${card.difficulty}'),
                    Text(
                      card.localImage != null
                          ? 'Image: ${card.localImage!.filename} · local selection'
                          : card.imageReference != null
                          ? 'Image: existing private reference'
                          : 'Image: unavailable',
                    ),
                    if (card.localImage != null)
                      Semantics(
                        label: 'Selected image preview',
                        image: true,
                        child: Image.memory(
                          card.localImage!.bytes,
                          height: 120,
                          fit: BoxFit.contain,
                          cacheWidth: 240,
                          errorBuilder: (_, _, _) =>
                              const Text('Image preview unavailable.'),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      '${card.state} · ${card.revision == 0 ? 'New local Card' : 'Revision ${card.revision}'}',
                    ),
                    if (owner)
                      Text(
                        'Creator: ${card.revision == 0 ? 'Inherited from Pack' : card.createdByUid ?? 'Unassigned legacy content'}',
                      ),
                    if (card.pending != null) ...[
                      Text(switch (card.pending!.status) {
                        DraftStatus.draft => 'Draft — saved locally',
                        DraftStatus.unsent => 'Unsent commit — queued locally',
                        DraftStatus.conflict =>
                          'Conflict — review before queueing',
                      }),
                      Text('Pending Card change: ${card.pending!.action}'),
                      if (card.localImage != null)
                        const Text(
                          'Selected image has not been uploaded. This commit remains local.',
                        ),
                      Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          if (card.pending!.status == DraftStatus.draft)
                            TextButton(
                              onPressed: () => _run(
                                context,
                                () => controller.queueDraft(card.pending!.id),
                              ),
                              child: const Text('Queue Card commit'),
                            ),
                          if (eligible &&
                              card.pending!.status != DraftStatus.conflict &&
                              {
                                'create',
                                'update',
                              }.contains(card.pending!.action))
                            TextButton(
                              onPressed: () => _edit(context, card),
                              child: const Text('Edit Card'),
                            ),
                          TextButton(
                            onPressed: () => _run(
                              context,
                              () => controller.discardDraft(card.pending!.id),
                            ),
                            child: const Text('Discard Card change'),
                          ),
                        ],
                      ),
                    ] else ...[
                      const Text('Synced'),
                      Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          if (eligible &&
                              {'active', 'hidden'}.contains(card.state))
                            TextButton(
                              onPressed: () => _edit(context, card),
                              child: const Text('Edit Card'),
                            ),
                          if (eligible && card.state == 'active')
                            TextButton(
                              onPressed: () => _run(
                                context,
                                () => controller.hideCard(
                                  card.id,
                                  expectedRevision: card.revision,
                                ),
                              ),
                              child: const Text('Hide Card'),
                            ),
                          if (owner &&
                              {'active', 'hidden'}.contains(card.state))
                            TextButton(
                              onPressed: () =>
                                  _confirm(context, card, 'delete'),
                              child: const Text('Delete Card'),
                            ),
                          if (owner && card.state == 'deleted') ...[
                            if (eligible)
                              TextButton(
                                onPressed: () =>
                                    _confirm(context, card, 'restore'),
                                child: const Text('Restore Card'),
                              ),
                            TextButton(
                              onPressed: () =>
                                  _confirm(context, card, 'permanently delete'),
                              child: const Text('Permanently delete Card'),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }

  void _edit(BuildContext context, CardSummary card) => showDialog<void>(
    context: context,
    builder: (_) => CardDraftDialog(
      controller: widget.controller,
      packId: card.packId,
      card: card,
    ),
  );
  void _confirm(BuildContext context, CardSummary card, String action) =>
      showDialog<void>(
        context: context,
        builder: (_) => _CardConfirmation(
          controller: widget.controller,
          card: card,
          action: action,
        ),
      );
}

Future<void> _run(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(cardFailureMessage(error))));
    }
  }
}

Future<void> showPackCards(
  BuildContext context,
  DatasetController controller,
  String packId,
) => showDialog<void>(
  context: context,
  builder: (_) => _PackCardReview(controller: controller, packId: packId),
);

class _PackCardReview extends StatefulWidget {
  const _PackCardReview({required this.controller, required this.packId});
  final DatasetController controller;
  final String packId;
  @override
  State<_PackCardReview> createState() => _PackCardReviewState();
}

class _PackCardReviewState extends State<_PackCardReview> {
  late final String? _scope;
  bool _closed = false;
  @override
  void initState() {
    super.initState();
    _scope = widget.controller.scope?.namespace;
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (_closed || _scope == widget.controller.scope?.namespace) return;
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

  @override
  Widget build(BuildContext context) => _closed
      ? const SizedBox.shrink()
      : Dialog.fullscreen(
          child: SafeArea(
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close Card review'),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: CardsPage(
                      controller: widget.controller,
                      initialPackId: widget.packId,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
}

class _CardConfirmation extends StatefulWidget {
  const _CardConfirmation({
    required this.controller,
    required this.card,
    required this.action,
  });
  final DatasetController controller;
  final CardSummary card;
  final String action;
  @override
  State<_CardConfirmation> createState() => _CardConfirmationState();
}

class _CardConfirmationState extends State<_CardConfirmation> {
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
        _scope == widget.controller.scope?.namespace &&
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
      final card = widget.card;
      switch (widget.action) {
        case 'delete':
          await controller.deleteCard(card.id, expectedRevision: card.revision);
        case 'restore':
          await controller.restoreCard(
            card.id,
            expectedRevision: card.revision,
          );
        case 'permanently delete':
          await controller.purgeCard(card.id, expectedRevision: card.revision);
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
    final action = widget.action;
    return AlertDialog(
      title: Text('${action[0].toUpperCase()}${action.substring(1)} Card?'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.card.name),
              Text('Card ID: ${widget.card.id}'),
              const SizedBox(height: 12),
              Text(switch (action) {
                'delete' => 'Soft deletion retains the Card identity and Pack relationship.',
                'restore' => 'Restore only this Card into hidden state. Its Pack must be eligible.',
                _ => 'Permanent deletion cannot be undone after upload.',
              }),
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
