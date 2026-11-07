import 'package:flutter/material.dart';

// Public navigation metadata only. These routes confer no authorization.
enum StudioRoute {
  dashboard('/dashboard', 'Dashboard', Icons.dashboard_outlined),
  topics('/topics', 'Topics', Icons.category_outlined),
  myPacks('/my-packs', 'My Packs', Icons.inventory_2_outlined),
  cards('/cards', 'Cards', Icons.style_outlined),
  profile('/profile', 'Profile', Icons.person_outline),
  login('/login', 'Sign in', Icons.login),
  notFound('/not-found', 'Page not found', Icons.search_off);

  const StudioRoute(this.path, this.label, this.icon);
  final String path;
  final String label;
  final IconData icon;

  static const destinations = [dashboard, topics, myPacks, cards, profile];

  static StudioRoute fromUri(Uri uri) {
    if (uri.path == '/' || uri.path.isEmpty) return dashboard;
    return values.firstWhere(
      (route) => route.path == uri.path,
      orElse: () => notFound,
    );
  }
}
