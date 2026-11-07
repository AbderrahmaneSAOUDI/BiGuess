import 'package:flutter/material.dart';

import '../app/studio_theme.dart';

enum StudioStatusKind { empty, loading, offline, error }

// Presentation states for future data adapters; no connectivity probe or IO.
class StudioStatus extends StatelessWidget {
  const StudioStatus({
    super.key,
    this.kind = StudioStatusKind.empty,
    this.icon = Icons.space_dashboard_outlined,
    required this.title,
    required this.message,
  });

  final StudioStatusKind kind;
  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: kind != StudioStatusKind.empty,
    child: Card.outlined(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF0F5EF),
                borderRadius: BorderRadius.circular(18),
              ),
              child: kind == StudioStatusKind.loading
                  ? const SizedBox.square(
                      dimension: 28,
                      child: CircularProgressIndicator(
                        semanticsLabel: 'Loading',
                      ),
                    )
                  : Icon(
                      switch (kind) {
                        StudioStatusKind.offline => Icons.cloud_off_outlined,
                        StudioStatusKind.error => Icons.error_outline,
                        _ => icon,
                      },
                      size: 28,
                      color: const Color(0xFF42634E),
                    ),
            ),
            const SizedBox(height: 24),
            Semantics(
              header: true,
              child: Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Text(message, textAlign: TextAlign.center),
            ),
            if (kind == StudioStatusKind.empty) ...[
              const SizedBox(height: 20),
              const Text(
                'A little more time. A lot to look forward to.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: StudioTheme.muted),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
