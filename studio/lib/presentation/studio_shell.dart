import 'package:flutter/material.dart';

import '../app/studio_route.dart';
import '../app/studio_theme.dart';
import 'studio_brand.dart';
import 'studio_status.dart';
import 'studio_welcome.dart';

class StudioShell extends StatelessWidget {
  const StudioShell({super.key, required this.route, required this.onNavigate});

  final StudioRoute route;
  final ValueChanged<StudioRoute> onNavigate;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final textScale = (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(
        1.0,
        double.infinity,
      );
      final wide =
          constraints.maxWidth >= StudioTheme.wideBreakpoint * textScale &&
          constraints.maxHeight >= 600 * textScale;
      final signIn = Padding(
        padding: const EdgeInsets.only(right: 20),
        child: OutlinedButton.icon(
          onPressed: () => onNavigate(StudioRoute.login),
          icon: const Icon(Icons.login_rounded, size: 17),
          label: const Text('Sign in'),
        ),
      );
      return Scaffold(
        appBar: wide
            ? null
            : AppBar(
                titleSpacing: 0,
                title: const StudioBrand(),
                actions: [signIn],
              ),
        drawer: wide
            ? null
            : Drawer(
                backgroundColor: StudioTheme.sidebar,
                child: SafeArea(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(12, 20, 12, 32),
                          child: StudioBrand(onDark: true),
                        ),
                        for (final destination in StudioRoute.destinations)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: ListTile(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              leading: Icon(destination.icon),
                              title: Text(destination.label),
                              textColor: const Color(0xFFC1D0C8),
                              iconColor: const Color(0xFFC1D0C8),
                              selectedColor: StudioTheme.mint,
                              selectedTileColor: const Color(0xFF284A3E),
                              selected: destination == route,
                              onTap: () {
                                Navigator.of(context).pop();
                                onNavigate(destination);
                              },
                            ),
                          ),
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: PreviewBadge(onDark: true),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide) _Sidebar(route: route, onNavigate: onNavigate),
            Expanded(
              child: Column(
                children: [
                  if (wide)
                    Container(
                      height: 80,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        border: Border(
                          bottom: BorderSide(color: StudioTheme.line),
                        ),
                      ),
                      padding: const EdgeInsets.only(left: 40),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.grid_view_rounded,
                            size: 16,
                            color: StudioTheme.muted,
                          ),
                          const SizedBox(width: 12),
                          const Text(
                            'Workspace',
                            style: TextStyle(fontWeight: FontWeight.w500),
                          ),
                          const Spacer(),
                          if (constraints.maxWidth >= 1100) ...[
                            const PreviewBadge(),
                            const SizedBox(width: 24),
                          ],
                          signIn,
                        ],
                      ),
                    ),
                  Expanded(
                    child: FocusTraversalGroup(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(
                          wide ? 40 : 20,
                          wide ? 36 : 24,
                          wide ? 40 : 20,
                          28,
                        ),
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1080),
                            child: _PlaceholderPage(route: route),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.route, required this.onNavigate});

  final StudioRoute route;
  final ValueChanged<StudioRoute> onNavigate;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 240,
    child: ColoredBox(
      color: StudioTheme.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 30, 20, 40),
            child: StudioBrand(onDark: true),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(28, 0, 24, 16),
            child: Text(
              'WORKSPACE',
              style: TextStyle(
                color: Color(0xFFABC1B5),
                fontSize: 10,
                letterSpacing: 1.8,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: NavigationRail(
              extended: true,
              minExtendedWidth: 240,
              backgroundColor: StudioTheme.sidebar,
              indicatorColor: const Color(0xFF34594A),
              selectedIconTheme: const IconThemeData(
                color: StudioTheme.mint,
                size: 21,
              ),
              unselectedIconTheme: const IconThemeData(
                color: Color(0xFFB8CCC0),
                size: 21,
              ),
              selectedLabelTextStyle: const TextStyle(
                color: StudioTheme.mint,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
              unselectedLabelTextStyle: const TextStyle(
                color: Color(0xFFB8CCC0),
                fontSize: 14,
              ),
              selectedIndex: !StudioRoute.destinations.contains(route)
                  ? null
                  : StudioRoute.destinations.indexOf(route),
              onDestinationSelected: (index) =>
                  onNavigate(StudioRoute.destinations[index]),
              destinations: [
                for (final destination in StudioRoute.destinations)
                  NavigationRailDestination(
                    icon: Icon(destination.icon),
                    label: Text(destination.label),
                  ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Divider(color: Color(0xFF3B5549)),
                SizedBox(height: 16),
                PreviewBadge(onDark: true),
                SizedBox(height: 12),
                Text(
                  'A new space for\nplayful possibilities.',
                  style: TextStyle(
                    color: Color(0xFFB8CCC0),
                    fontSize: 12,
                    height: 1.6,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _PlaceholderPage extends StatelessWidget {
  const _PlaceholderPage({required this.route});

  final StudioRoute route;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'YOUR CREATIVE SPACE',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          letterSpacing: 1.8,
          color: StudioTheme.muted,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 8),
      Semantics(
        header: true,
        child: Text(
          route.label,
          style: Theme.of(context).textTheme.headlineLarge,
        ),
      ),
      const SizedBox(height: 12),
      Text(switch (route) {
        StudioRoute.dashboard => 'Good ideas. Great guesses. All in one place.',
        StudioRoute.topics =>
          'Every collection begins with a little curiosity.',
        StudioRoute.myPacks => 'A place for the collections you make your own.',
        StudioRoute.cards => 'The small cards behind the big questions.',
        StudioRoute.profile => 'Your own corner of BiGuess Studio.',
        StudioRoute.login => 'Your workspace will be waiting for you.',
        StudioRoute.notFound => 'Let’s find your way back to the workspace.',
      }),
      const SizedBox(height: 28),
      if (route == StudioRoute.dashboard) ...[
        const StudioWelcome(),
        const SizedBox(height: 24),
      ],
      StudioStatus(
        icon: route.icon,
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
      const Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Icon(Icons.info_outline_rounded, size: 16, color: StudioTheme.muted),
          Text(
            'This preview works without a backend connection. Content management is not enabled.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    ],
  );
}
