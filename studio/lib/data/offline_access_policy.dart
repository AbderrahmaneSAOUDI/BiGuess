import 'dart:convert';

import 'offline_access_policy_stub.dart'
    if (dart.library.js_interop) 'offline_access_policy_web.dart'
    as platform;

/// Same-tab offline readiness is separate from the IndexedDB dataset receipt.
/// These markers contain no content, token or role and grant no online access.
/// Both stores must remain available; fresh online authorization is required in
/// a new tab without its readiness marker. Reloads retain browser session storage.
class OfflineAccessPolicy {
  OfflineAccessPolicy({
    bool Function(String)? readMarker,
    void Function(String)? writeMarker,
    void Function(String)? removeMarker,
  }) : _read = readMarker ?? platform.readMarker,
       _write = writeMarker ?? platform.writeMarker,
       _remove = removeMarker ?? platform.removeMarker;

  static final _denials = <String>{};
  final bool Function(String) _read;
  final void Function(String) _write;
  final void Function(String) _remove;
  String _key(String project, String uid) =>
      'biguess-studio-offline-ready:${jsonEncode([project, uid])}';

  bool denied(String project, String uid) {
    final key = _key(project, uid);
    if (_denials.contains(key)) return true;
    try {
      if (!_read(key)) {
        _denials.add(key);
        return true;
      }
      // Same-value replacement allocates no additional storage. A browser that
      // still permits reads but blocks all writes cannot reuse a stale marker
      // after a denial could not be persisted before a reload.
      _write(key);
      return false;
    } catch (_) {
      _denials.add(key);
      return true;
    }
  }

  void deny(String project, String uid) {
    final key = _key(project, uid);
    _denials.add(key);
    // Removing an existing marker frees quota; recording a denial never needs
    // to allocate a new session-storage entry while the browser is full.
    try {
      _remove(key);
    } catch (_) {
      /* Memory remains denied. */
    }
  }

  /// Call only after fresh successful Worker authorization for this identity.
  /// Offline access additionally requires a complete account-bound DB snapshot.
  void allow(String project, String uid) {
    final key = _key(project, uid);
    try {
      _write(key);
      _denials.remove(key);
    } catch (_) {
      _denials.add(key);
    }
  }
}
