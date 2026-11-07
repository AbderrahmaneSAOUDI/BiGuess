import 'package:flutter/material.dart';

abstract final class StudioTheme {
  static const wideBreakpoint = 800.0;
  static const ink = Color(0xFF192D29);
  static const muted = Color(0xFF5C6E66);
  static const canvas = Color(0xFFF7F8F4);
  static const sidebar = Color(0xFF142D28);
  static const mint = Color(0xFFC5EBD6);
  static const line = Color(0xFFDEE5DF);

  static ThemeData get light {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF24664D),
        surface: Colors.white,
      ),
    );
    return base.copyWith(
      scaffoldBackgroundColor: canvas,
      dividerColor: line,
      textTheme: base.textTheme
          .apply(bodyColor: ink, displayColor: ink)
          .copyWith(
            headlineLarge: const TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w700,
              letterSpacing: -1.2,
              color: ink,
            ),
            titleLarge: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.4,
              color: ink,
            ),
            bodyMedium: const TextStyle(
              fontSize: 14,
              height: 1.6,
              color: muted,
            ),
            bodyLarge: const TextStyle(fontSize: 16, height: 1.6, color: muted),
          ),
      appBarTheme: const AppBarTheme(
        backgroundColor: canvas,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 76,
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          minimumSize: const Size(48, 44),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          side: const BorderSide(color: line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: line),
        ),
      ),
    );
  }
}
