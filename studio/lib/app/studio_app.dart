import 'package:flutter/material.dart';

import '../presentation/studio_shell.dart';
import 'studio_route.dart';
import 'studio_theme.dart';

class StudioApp extends StatefulWidget {
  const StudioApp({super.key});

  @override
  State<StudioApp> createState() => _StudioAppState();
}

class _StudioAppState extends State<StudioApp> {
  final _router = StudioRouter();

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'BiGuess Studio',
    debugShowCheckedModeBanner: false,
    theme: StudioTheme.light,
    routerDelegate: _router,
    routeInformationParser: const StudioRouteParser(),
  );
}

class StudioRouteParser extends RouteInformationParser<StudioRoute> {
  const StudioRouteParser();

  @override
  Future<StudioRoute> parseRouteInformation(
    RouteInformation routeInformation,
  ) async => StudioRoute.fromUri(routeInformation.uri);

  @override
  RouteInformation restoreRouteInformation(StudioRoute configuration) =>
      RouteInformation(uri: Uri(path: configuration.path));
}

class StudioRouter extends RouterDelegate<StudioRoute>
    with ChangeNotifier, PopNavigatorRouterDelegateMixin<StudioRoute> {
  StudioRoute _route = StudioRoute.dashboard;

  @override
  final navigatorKey = GlobalKey<NavigatorState>();

  @override
  StudioRoute get currentConfiguration => _route;

  void navigate(StudioRoute route) {
    if (_route == route) return;
    _route = route;
    notifyListeners();
  }

  @override
  Future<void> setNewRoutePath(StudioRoute configuration) async {
    _route = configuration;
  }

  @override
  Widget build(BuildContext context) => Navigator(
    key: navigatorKey,
    pages: [
      MaterialPage<void>(
        key: const ValueKey('studio-shell'),
        child: StudioShell(route: _route, onNavigate: navigate),
      ),
    ],
    onDidRemovePage: (_) {},
  );
}
