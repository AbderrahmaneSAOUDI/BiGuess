import 'package:flutter/material.dart';

import '../app/studio_route.dart';
import '../presentation/studio_shell.dart';
import '../data/dataset_controller.dart';
import 'studio_session.dart';

class StudioAuthGate extends StatefulWidget {
  const StudioAuthGate({
    super.key,
    required this.session,
    required this.route,
    required this.onNavigate,
    this.dataset,
  });
  final StudioSession session;
  final StudioRoute route;
  final ValueChanged<StudioRoute> onNavigate;
  final DatasetController? dataset;
  @override
  State<StudioAuthGate> createState() => _StudioAuthGateState();
}

class _StudioAuthGateState extends State<StudioAuthGate>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.session.resume();
    } else if (state != AppLifecycleState.inactive) {
      widget.session.suspend();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.session, widget.dataset]),
    builder: (context, _) {
      final session = widget.session;
      final offline =
          session.phase == SessionPhase.offline &&
          widget.dataset?.phase == DatasetPhase.offline;
      final cachedScope = widget.dataset?.scope;
      if (session.phase == SessionPhase.authorized || offline) {
        return StudioShell(
          key: ValueKey(session.principal?.uid ?? cachedScope!.uid),
          route: widget.route == StudioRoute.login
              ? StudioRoute.dashboard
              : widget.route,
          onNavigate: widget.onNavigate,
          principal:
              session.principal ??
              StudioPrincipal(cachedScope!.uid, '', cachedScope.role),
          dataset: widget.dataset,
          onLogout: session.logout,
          onSwitchAccount: session.switchAccount,
        );
      }
      final busy =
          session.phase == SessionPhase.restoring ||
          session.phase == SessionPhase.checking ||
          (session.phase == SessionPhase.offline &&
              widget.dataset?.busy == true);
      return Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(switch (session.phase) {
                    SessionPhase.denied => 'Access denied',
                    SessionPhase.unavailable => 'Google sign-in completed',
                    SessionPhase.restoring => 'Restoring session',
                    SessionPhase.checking => 'Checking access',
                    SessionPhase.offline => 'Offline workspace',
                    _ => 'Sign in to BiGuess Studio',
                  }, style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 20),
                  if (busy)
                    const CircularProgressIndicator()
                  else ...[
                    Text(
                      session.phase == SessionPhase.offline
                          ? 'No completed authorized dataset is available for this account. Reconnect to verify access and synchronize. Site storage may have been blocked, evicted or cleared.'
                          : session.phase == SessionPhase.denied
                          ? 'This account is not authorized to use Studio.'
                          : _message(session.errorCode),
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: () => session.signIn(),
                      child: const Text('Continue with Google'),
                    ),
                    TextButton(
                      onPressed: () => session.signIn(redirect: true),
                      child: const Text('Use redirect sign-in'),
                    ),
                    if (session.phase != SessionPhase.signedOut) ...[
                      TextButton(
                        onPressed: () => session.validate(refresh: true),
                        child: const Text('Retry access check'),
                      ),
                      TextButton(
                        onPressed: session.logout,
                        child: const Text('Sign out'),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  String _message(String? code) => switch (code) {
    null => 'Only accounts authorized by the Studio owner can continue.',
    'backend-not-configured' =>
      'Studio access is not enabled yet. No private content is available.',
    'popup-closed-by-user' ||
    'cancelled-popup-request' => 'Sign-in was cancelled. Try again when ready.',
    'popup-blocked' => 'Your browser blocked the popup. Allow popups for this site and try again.',
    'web-storage-unsupported' ||
    'operation-not-supported-in-this-environment' ||
    'missing-initial-state' => 'Browser storage or this sign-in flow is blocked. Use a supported browser with site storage enabled.',
    'unauthorized-domain' || 'operation-not-allowed' => 'Google sign-in is not configured for this site. Contact the Studio owner.',
    'session-expired' ||
    'user-token-expired' ||
    'invalid-user-token' ||
    'user-disabled' =>
      'Your session has expired or was revoked. Sign in again.',
    _ => 'Could not verify access. Check your connection and try again. No Studio content is available.',
  };
}
