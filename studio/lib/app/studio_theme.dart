import 'package:flutter/material.dart';

abstract final class StudioTheme {
  static const wideBreakpoint = 800.0;
  // Logo colors. Keep the multicolor identity in the logo, with a blue UI accent.
  static const blue = Color(0xFF68B8F8);
  static const green = Color(0xFF38A858);
  static const coral = Color(0xFFE84838);
  static const yellow = Color(0xFFF8E8A8);
  static const primary = Color(0xFF175D93);
  static const ink = Color(0xFF27272A);
  static const muted = Color(0xFF626268);
  static const canvas = Color(0xFFFFFFFF);
  static const sidebar = Color(0xFFFAFAFA);
  static const selected = Color(0xFFECF5FD);
  static const line = Color(0xFFE7E7EA);

  static ThemeData get light {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: blue,
        primary: primary,
        surface: Colors.white,
        onSurface: ink,
      ),
    );
    return base.copyWith(
      scaffoldBackgroundColor: canvas,
      dividerColor: line,
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
