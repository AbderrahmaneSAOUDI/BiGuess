import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import 'app/studio_app.dart';
import 'auth/firebase_identity.dart';
import 'auth/studio_session.dart';
import 'auth/worker_authorization.dart';
import 'data/dataset_api.dart';
import 'data/dataset_controller.dart';
import 'data/network_state.dart';
import 'data/image_ingestion.dart';
import 'data/publication_api.dart';

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
    final network = BrowserNetwork();
    final authorizationClient = http.Client();
    final session = StudioSession(
      FirebaseIdentity(FirebaseAuth.instanceFor(app: app)),
      apiBase.isEmpty
          ? const DisabledStudioAuthorization()
          : WorkerAuthorization(Uri.parse(apiBase), authorizationClient),
      online: () => network.online,
      connectionChanges: network.changes,
    );
    final dataset = apiBase.isEmpty
        ? null
        : DatasetController(
            projectId: projectId,
            session: session,
            api: WorkerDatasetApi(Uri.parse(apiBase), http.Client()),
            publication: WorkerPublicationApi(
              Uri.parse(apiBase),
              http.Client(),
            ),
            imageIngestion: WorkerImageIngestionApi(
              Uri.parse(apiBase),
              http.Client(),
            ),
          );
    dataset?.start();
    runApp(
      StudioApp(
        session: session,
        dataset: dataset,
        onDispose: () {
          dataset?.dispose();
          session.dispose();
          network.dispose();
          authorizationClient.close();
        },
      ),
    );
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
