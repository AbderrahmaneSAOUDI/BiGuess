import 'package:flutter/material.dart';

abstract final class StudioTheme {
  static const wideBreakpoint = 800.0;

  static ThemeData get light => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF315C49)),
    scaffoldBackgroundColor: const Color(0xFFF6F8F5),
    appBarTheme: const AppBarTheme(backgroundColor: Color(0xFFF6F8F5)),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
    ),
  );
}
