import 'package:flutter/material.dart';

import '../app/studio_theme.dart';

class StudioBrand extends StatelessWidget {
  const StudioBrand({super.key, this.onDark = false});

  final bool onDark;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: onDark ? StudioTheme.mint : StudioTheme.sidebar,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Icons.style_rounded,
              size: 22,
              color: onDark ? StudioTheme.sidebar : StudioTheme.mint,
            ),
          ),
        ),
        if (constraints.maxWidth >= 150) ...[
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              'BiGuess Studio',
              style: TextStyle(
                color: onDark ? Colors.white : StudioTheme.ink,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

class PreviewBadge extends StatelessWidget {
  const PreviewBadge({super.key, this.onDark = false});

  final bool onDark;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: BoxDecoration(
      color: onDark ? const Color(0xFF24453A) : const Color(0xFFE8F1E9),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      'PUBLIC PREVIEW',
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.4,
        color: onDark ? StudioTheme.mint : const Color(0xFF285D45),
      ),
    ),
  );
}
