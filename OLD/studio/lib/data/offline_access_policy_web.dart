import 'package:web/web.dart' as web;

bool readMarker(String key) =>
    web.window.sessionStorage.getItem(key) == 'ready';
void writeMarker(String key) => web.window.sessionStorage.setItem(key, 'ready');
void removeMarker(String key) => web.window.sessionStorage.removeItem(key);
