import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

class BrowserNetwork {
  BrowserNetwork() {
    _listener = ((web.Event _) {
      _changes.add(online);
    }).toJS;
    web.window.addEventListener('online', _listener);
    web.window.addEventListener('offline', _listener);
  }
  final _changes = StreamController<bool>.broadcast(sync: true);
  late final JSFunction _listener;
  bool get online => web.window.navigator.onLine;
  Stream<bool> get changes => _changes.stream;
  void dispose() {
    web.window.removeEventListener('online', _listener);
    web.window.removeEventListener('offline', _listener);
    unawaited(_changes.close());
  }
}
