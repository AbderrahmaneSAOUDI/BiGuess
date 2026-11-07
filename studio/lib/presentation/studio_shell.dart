import 'package:flutter/material.dart';

import '../app/studio_route.dart';
import '../app/studio_theme.dart';
import 'studio_status.dart';

class StudioShell extends StatelessWidget {
  const StudioShell({super.key, required this.route, required this.onNavigate});

  final StudioRoute route;
  final ValueChanged<StudioRoute> onNavigate;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= StudioTheme.wideBreakpoint;
      return Scaffold(
        appBar: AppBar(
          title: const Text('BiGuess Studio'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: TextButton.icon(
                onPressed: () => onNavigate(StudioRoute.login),
                icon: const Icon(Icons.login),
                label: const Text('Sign in'),
              ),
            ),
          ],
        ),
        drawer: wide
            ? null
            : Drawer(
                child: SafeArea(
                  child: ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('Studio navigation'),
                      ),
                      for (final destination in StudioRoute.destinations)
                        ListTile(
                          leading: Icon(destination.icon),
                          title: Text(destination.label),
                          selected: destination == route,
                          onTap: () {
                            Navigator.of(context).pop();
                            onNavigate(destination);
                          },
                        ),
                    ],
                  ),
                ),
              ),
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide) ...[
              NavigationRail(
                extended: constraints.maxWidth >= 1100,
                selectedIndex: !StudioRoute.destinations.contains(route)
                    ? null
                    : StudioRoute.destinations.indexOf(route),
                onDestinationSelected: (index) =>
                    onNavigate(StudioRoute.destinations[index]),
                labelType: constraints.maxWidth >= 1100
                    ? NavigationRailLabelType.none
                    : NavigationRailLabelType.all,
                destinations: [
                  for (final destination in StudioRoute.destinations)
                    NavigationRailDestination(
                      icon: Icon(destination.icon),
                      label: Text(destination.label),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
            ],
            Expanded(
              child: FocusTraversalGroup(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(wide ? 40 : 16),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 960),
                      child: _PlaceholderPage(route: route),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _PlaceholderPage extends StatelessWidget {
  const _PlaceholderPage({required this.route});

  final StudioRoute route;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('WORKSPACE PREVIEW', style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 12),
      Semantics(
        header: true,
        child: Text(
          route.label,
          style: Theme.of(context).textTheme.headlineLarge,
        ),
      ),
      const SizedBox(height: 24),
      StudioStatus(
        kind: route == StudioRoute.notFound
            ? StudioStatusKind.error
            : StudioStatusKind.empty,
        title: switch (route) {
          StudioRoute.login => 'Sign-in is not available yet',
          StudioRoute.notFound => 'This page is unavailable',
          _ => 'Studio under construction',
        },
        message: switch (route) {
          StudioRoute.login => 'Authentication is not connected. No account details are collected.',
          StudioRoute.notFound =>
            'Choose a page from the Studio navigation to continue.',
          StudioRoute.dashboard => 'Welcome to BiGuess Studio. This public preview contains no content or account data.',
          StudioRoute.profile => 'No profile is connected. Account information will appear here in a future release.',
          _ => 'No content is available in this preview.',
        },
      ),
      const SizedBox(height: 24),
      const Text(
        'This preview works without a backend connection. Content management is not enabled.',
      ),
    ],
  );
}
