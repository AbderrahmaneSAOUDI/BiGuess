import 'package:flutter/material.dart';

import '../presentation/studio_shell.dart';
import '../auth/studio_session.dart';
import '../auth/studio_auth_gate.dart';
import 'studio_route.dart';
import 'studio_theme.dart';

class StudioApp extends StatefulWidget {
  const StudioApp({super.key, this.session});

  final StudioSession? session;

  @override
  State<StudioApp> createState() => _StudioAppState();
}

class _StudioAppState extends State<StudioApp> {
  late final _router = StudioRouter(session: widget.session);

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
  StudioRouter({this.session});
  final StudioSession? session;
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
        child: session == null
            ? StudioShell(route: _route, onNavigate: navigate)
            : StudioAuthGate(
                session: session!,
                route: _route,
                onNavigate: navigate,
              ),
      ),
    ],
    onDidRemovePage: (_) {},
  );
}
