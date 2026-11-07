import 'package:flutter/material.dart';

enum StudioStatusKind { empty, loading, offline, error }

// Presentation states for future data adapters; no connectivity probe or IO.
class StudioStatus extends StatelessWidget {
  const StudioStatus({
    super.key,
    this.kind = StudioStatusKind.empty,
    required this.title,
    required this.message,
  });

  final StudioStatusKind kind;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: kind != StudioStatusKind.empty,
    child: Card.outlined(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (kind == StudioStatusKind.loading)
              const SizedBox.square(
                dimension: 28,
                child: CircularProgressIndicator(semanticsLabel: 'Loading'),
              )
            else
              Icon(switch (kind) {
                StudioStatusKind.offline => Icons.cloud_off_outlined,
                StudioStatusKind.error => Icons.error_outline,
                _ => Icons.space_dashboard_outlined,
              }, size: 36),
            const SizedBox(height: 20),
            Semantics(
              header: true,
              child: Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    ),
  );
}
