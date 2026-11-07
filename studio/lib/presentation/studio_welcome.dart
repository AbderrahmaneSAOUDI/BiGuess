import 'package:flutter/material.dart';

import '../app/studio_theme.dart';
import 'studio_brand.dart';

class StudioWelcome extends StatelessWidget {
  const StudioWelcome({super.key});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 650;
      return Container(
        padding: EdgeInsets.all(wide ? 36 : 24),
        decoration: BoxDecoration(
          color: const Color(0xFFE8F0E5),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFFDCE7D9)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const PreviewBadge(),
                  const SizedBox(height: 24),
                  Text(
                    'Made for the curious.',
                    style: TextStyle(
                      fontSize: wide ? 46 : 32,
                      height: 1.08,
                      letterSpacing: -1.6,
                      fontWeight: FontWeight.w700,
                      color: StudioTheme.ink,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 380),
                    child: Text(
                      'A space to shape the cards behind your next great game.',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ),
                ],
              ),
            ),
            if (wide) ...[const SizedBox(width: 24), const _CardIllustration()],
          ],
        ),
      );
    },
  );
}

class _CardIllustration extends StatelessWidget {
  const _CardIllustration();

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: 220,
      height: 240,
      child: Stack(
        alignment: Alignment.center,
        children: [
          for (final (angle, color, offset) in [
            (-0.22, const Color(0xFFABCEB5), const Offset(-27, 0)),
            (0.18, const Color(0xFF43755A), const Offset(28, 4)),
            (-0.04, StudioTheme.sidebar, const Offset(0, -6)),
          ])
            Transform.translate(
              offset: offset,
              child: Transform.rotate(
                angle: angle,
                child: Container(
                  width: 142,
                  height: 194,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0x55FFFFFF)),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x14223B2D),
                        blurRadius: 20,
                        offset: Offset(0, 12),
                      ),
                    ],
                  ),
                  child: color == StudioTheme.sidebar
                      ? const Center(
                          child: Icon(
                            Icons.question_mark_rounded,
                            size: 74,
                            color: StudioTheme.mint,
                          ),
                        )
                      : null,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
