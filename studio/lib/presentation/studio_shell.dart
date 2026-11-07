import 'package:flutter/material.dart';

import '../app/studio_route.dart';
import '../app/studio_icon_asset.dart';
import '../app/studio_theme.dart';
import 'studio_brand.dart';
import 'studio_icon.dart';
import 'studio_status.dart';

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
          icon: const StudioIcon(StudioIconAsset.signIn, size: 18),
          label: const Text('Sign in'),
        ),
      );
      return Scaffold(
        appBar: wide
            ? null
            : AppBar(
                leading: Builder(
                  builder: (context) => IconButton(
                    tooltip: MaterialLocalizations.of(context)
                        .openAppDrawerTooltip,
                    icon: const StudioIcon(StudioIconAsset.menu),
                    onPressed: () => Scaffold.of(context).openDrawer(),
                  ),
                ),
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
                          padding: EdgeInsets.fromLTRB(12, 12, 12, 28),
                          child: StudioBrand(),
                        ),
                        for (final destination in StudioRoute.destinations)
                          ListTile(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                            ),
                            leading: StudioIcon(destination.icon, size: 20),
                            title: Text(destination.label),
                            textColor: StudioTheme.muted,
                            iconColor: StudioTheme.muted,
                            selectedColor: StudioTheme.primary,
                            selectedTileColor: StudioTheme.selected,
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
                      height: 68,
                      decoration: const BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: StudioTheme.line),
                        ),
                      ),
                      padding: const EdgeInsets.only(left: 32),
                      child: Row(
                        children: [
                          const Text(
                            'Studio',
                            style: TextStyle(color: StudioTheme.muted),
                          ),
                          const Spacer(),
                          signIn,
                        ],
                      ),
                    ),
                  Expanded(
                    child: FocusTraversalGroup(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.all(wide ? 32 : 20),
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1040),
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
  Widget build(BuildContext context) => Container(
    width: 224,
    decoration: const BoxDecoration(
      color: StudioTheme.sidebar,
      border: Border(right: BorderSide(color: StudioTheme.line)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 16, 16, 24),
          child: StudioBrand(),
        ),
        Expanded(
          child: NavigationRail(
            extended: true,
            minExtendedWidth: 223,
            backgroundColor: StudioTheme.sidebar,
            indicatorColor: StudioTheme.selected,
            selectedIconTheme: const IconThemeData(
              color: StudioTheme.primary,
              size: 20,
            ),
            unselectedIconTheme: const IconThemeData(
              color: StudioTheme.muted,
              size: 20,
            ),
            selectedLabelTextStyle: const TextStyle(
              color: StudioTheme.primary,
              fontWeight: FontWeight.w500,
              fontSize: 14,
            ),
            unselectedLabelTextStyle: const TextStyle(
              color: StudioTheme.muted,
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
                  icon: StudioIcon(destination.icon),
                  label: Text(destination.label),
                ),
            ],
          ),
        ),
      ],
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
      Semantics(
        header: true,
        child: Text(
          route.label,
          style: Theme.of(context).textTheme.headlineLarge,
        ),
      ),
      const SizedBox(height: 24),
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
          StudioRoute.dashboard =>
            'This Studio preview contains no content or account data.',
          StudioRoute.profile => 'No profile is connected.',
          _ => 'No content is available in this preview.',
        },
      ),
    ],
  );
}
