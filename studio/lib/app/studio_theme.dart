import 'package:flutter/material.dart';

import 'studio_brand_colors.dart';

abstract final class StudioTheme {
  static const wideBreakpoint = 800.0;
  static const primary = BiGuessColors.blue;
  static const ink = BiGuessColors.outline;
  static const muted = Color(0xFF626268);
  static const canvas = Color(0xFFFFFFFF);
  static const sidebar = Color(0xFFFAFAFA);
  // Blue at 8% over white; brand accents stay restrained on neutral surfaces.
  static const selected = Color(0xFFF0F5FE);
  static const line = Color(0xFFE7E7EA);

  static ThemeData get light {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: BiGuessColors.blue,
        primary: BiGuessColors.blue,
        onPrimary: BiGuessColors.outline,
        secondary: BiGuessColors.green,
        onSecondary: BiGuessColors.outline,
        tertiary: BiGuessColors.yellow,
        onTertiary: BiGuessColors.outline,
        error: BiGuessColors.red,
        // Neutral black keeps text readable on the exact brand red.
        onError: Colors.black,
        surface: Colors.white,
        onSurface: ink,
      ),
    );
    return base.copyWith(
      scaffoldBackgroundColor: canvas,
      dividerColor: line,
      focusColor: BiGuessColors.blue.withValues(alpha: 0.12),
      textTheme: base.textTheme
          .apply(bodyColor: ink, displayColor: ink)
          .copyWith(
            headlineLarge: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.5,
              color: ink,
            ),
            titleLarge: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: ink,
            ),
            bodyMedium: const TextStyle(
              fontSize: 14,
              height: 1.5,
              color: muted,
            ),
          ),
      appBarTheme: const AppBarTheme(
        backgroundColor: canvas,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 68,
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          overlayColor: BiGuessColors.blue,
          minimumSize: const Size(48, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          side: const BorderSide(color: line),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: line),
        ),
      ),
    );
  }
}
