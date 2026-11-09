import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import 'app/studio_app.dart';
import 'auth/firebase_identity.dart';
import 'auth/studio_session.dart';
import 'auth/worker_authorization.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  const apiKey = String.fromEnvironment('STUDIO_FIREBASE_API_KEY');
  const appId = String.fromEnvironment('STUDIO_FIREBASE_APP_ID');
  const projectId = String.fromEnvironment('STUDIO_FIREBASE_PROJECT_ID');
  const senderId = String.fromEnvironment(
    'STUDIO_FIREBASE_MESSAGING_SENDER_ID',
  );
  const authDomain = String.fromEnvironment('STUDIO_FIREBASE_AUTH_DOMAIN');
  const apiBase = String.fromEnvironment('STUDIO_API_BASE_URL');
  // No Firebase configuration keeps the automatic frontend deployment inert.
  // Identity alone never grants access to the independently gated Worker.
  if ([apiKey, appId, projectId, senderId, authDomain].any((v) => v.isEmpty)) {
    runApp(const StudioApp());
    return;
  }
  try {
    final app = await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: apiKey,
        appId: appId,
        messagingSenderId: senderId,
        projectId: projectId,
        authDomain: authDomain,
      ),
    ).timeout(const Duration(seconds: 20));
    final session = StudioSession(
      FirebaseIdentity(FirebaseAuth.instanceFor(app: app)),
      apiBase.isEmpty
          ? const _UnavailableAuthorization()
          : WorkerAuthorization(Uri.parse(apiBase), http.Client()),
    );
    runApp(StudioApp(session: session));
    await session.start();
  } catch (_) {
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text(
              'Studio sign-in is unavailable. Please reload and try again.',
            ),
          ),
        ),
      ),
    );
  }
}

class _UnavailableAuthorization implements StudioAuthorization {
  const _UnavailableAuthorization();
  @override
  Future<StudioPrincipal> lookup(String token) async =>
      throw const SessionFailure('authorization-unavailable');
}
