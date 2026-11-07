import 'package:flutter/material.dart';

import '../app/studio_theme.dart';
import '../app/studio_icon_asset.dart';
import 'studio_icon.dart';

enum StudioStatusKind { empty, loading, offline, error }

// Presentation states for future data adapters; no connectivity probe or IO.
class StudioStatus extends StatelessWidget {
  const StudioStatus({
    super.key,
    this.kind = StudioStatusKind.empty,
    this.icon = StudioIconAsset.dashboard,
    required this.title,
    required this.message,
  });

  final StudioStatusKind kind;
  final StudioIconAsset icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: kind != StudioStatusKind.empty,
    child: Card.outlined(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (kind == StudioStatusKind.loading)
              const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(semanticsLabel: 'Loading'),
              )
            else
              _StatusSymbol(kind: kind, icon: icon),
            const SizedBox(height: 20),
            Semantics(
              header: true,
              child: Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Text(message, textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    ),
  );
}

class _StatusSymbol extends StatelessWidget {
  const _StatusSymbol({required this.kind, required this.icon});

  final StudioStatusKind kind;
  final StudioIconAsset icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final symbol = StudioIcon(
      switch (kind) {
        StudioStatusKind.offline => StudioIconAsset.offline,
        StudioStatusKind.error => StudioIconAsset.error,
        _ => icon,
      },
      size: 24,
      color: switch (kind) {
        StudioStatusKind.offline => colors.onTertiary,
        StudioStatusKind.error => colors.error,
        _ => StudioTheme.muted,
      },
    );
    if (kind != StudioStatusKind.offline) return symbol;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colors.tertiary,
        borderRadius: BorderRadius.circular(4),
      ),
      child: symbol,
    );
  }
}
