// Standalone browser verification entrypoint, never imported by lib/main.dart.
// Synthetic identity uses sessionStorage only to model SDK identity restoration.
// All real dataset, session, routing and IndexedDB implementations are exercised.
import 'dart:async';

import 'package:biguess_studio/app/studio_app.dart';
import 'package:biguess_studio/auth/studio_session.dart';
import 'package:biguess_studio/auth/worker_authorization.dart';
import 'package:biguess_studio/data/dataset_api.dart';
import 'package:biguess_studio/data/dataset_controller.dart';
import 'package:biguess_studio/data/network_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

class FixtureIdentity implements StudioIdentity {
  FixtureIdentity() {
    final requested = Uri.base.queryParameters['account'];
    if (requested != null && {'a', 'b', 'new', 'owner'}.contains(requested)) {
      web.window.sessionStorage.setItem(_key, requested);
      web.window.history.replaceState(null, '', web.window.location.pathname);
    }
    _uid = web.window.sessionStorage.getItem(_key);
  }
  static const _key = 'biguess-browser-fixture-identity';
  String? _uid;
  final _changes = StreamController<String?>.broadcast(sync: true);

  @override
  Stream<String?> get changes async* {
    yield _uid;
    yield* _changes.stream;
  }

  @override
  Future<void> restore() async {}
  @override
  Future<String?> token({bool refresh = false}) async =>
      _uid == null ? null : 'token-$_uid';
  @override
  Future<void> popup() async {
    _uid = 'a';
    web.window.sessionStorage.setItem(_key, _uid!);
    _changes.add(_uid);
  }

  @override
  Future<void> redirect() => popup();
  @override
  Future<void> signOut() async {
    _uid = null;
    web.window.sessionStorage.removeItem(_key);
    _changes.add(null);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized().ensureSemantics();
  usePathUrlStrategy();
  final network = BrowserNetwork();
  final origin = Uri.parse(web.window.location.origin);
  final session = StudioSession(
    FixtureIdentity(),
    WorkerAuthorization(origin, http.Client()),
    online: () => network.online,
    connectionChanges: network.changes,
  );
  final dataset = DatasetController(
    projectId: 'browser-fixture',
    session: session,
    api: WorkerDatasetApi(origin, http.Client()),
  )..start();
  runApp(StudioApp(session: session, dataset: dataset));
  await session.start();
}
