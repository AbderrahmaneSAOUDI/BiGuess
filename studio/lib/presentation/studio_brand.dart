import 'package:flutter/material.dart';

import '../app/studio_theme.dart';

class StudioBrand extends StatelessWidget {
  const StudioBrand({super.key});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          'assets/brand/biguess_logo.webp',
          width: 32,
          height: 44,
          fit: BoxFit.contain,
          semanticLabel: 'BiGuess logo',
        ),
        if (constraints.maxWidth >= 150) ...[
          const SizedBox(width: 12),
          const Flexible(
            child: Text(
              'BiGuess Studio',
              style: TextStyle(
                color: StudioTheme.ink,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    ),
  );
}
