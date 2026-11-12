import 'package:flutter/foundation.dart';

import '../auth/studio_session.dart';
import 'dataset_api.dart';
import 'profile_api.dart';

/// Ephemeral private activity. It is never persisted or derived from local edits.
class ProfileController extends ChangeNotifier {
  ProfileController({required this.session, required this.api})
      : _lastUid = session.principal?.uid,
        _lastRole = session.principal?.role {
    session.addListener(_sessionChanged);
  }
  final StudioSession session;
  final ProfileApi? api;
  ContributorProfile? profile;
  String? errorCode;
  bool loading = false;
  int _generation = 0;
  bool _disposed = false;
  String? _lastUid;
  String? _lastRole;

  void _sessionChanged() {
    final principal = session.principal;
    final uid = principal?.uid;
    final role = principal?.role;
    if (session.phase != SessionPhase.authorized ||
        uid != _lastUid ||
        role != _lastRole) {
      _lastUid = uid;
      _lastRole = role;
      _generation++;
      profile = null;
      errorCode = null;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> refresh({String? contributorUid, bool more = false}) async {
    if (loading || _disposed) return;
    final prior = profile;
    if (more && prior?.nextCursor == null) return;
    final originalUid = session.identityUid ?? session.principal?.uid;
    loading = true;
    errorCode = null;
    _notify();
    int? requestGeneration;
    try {
      if (api == null) throw const DatasetApiFailure('profile-unavailable');
      await session.validate(refresh: true);
      if (_disposed || session.phase != SessionPhase.authorized) return;
      final principal = session.principal!;
      if (originalUid != principal.uid) return;
      final generation = _generation;
      requestGeneration = generation;
      bool active() =>
          !_disposed &&
          generation == _generation &&
          session.phase == SessionPhase.authorized &&
          session.principal?.uid == principal.uid &&
          session.principal?.role == principal.role;
      final token = session.tokenFor(principal.uid, principal.role);
      if (token == null) throw const DatasetApiFailure('session-expired');
      final filter = more ? prior!.contributorUid : contributorUid;
      if (filter != null && principal.role != 'owner_admin') {
        throw const DatasetApiFailure('forbidden');
      }
      final incoming = await api!.read(
        token,
        active,
        contributorUid: filter,
        cursor: more ? prior!.nextCursor : null,
      );
      if (!active()) return;
      final verified = await session.authorization.lookup(token);
      if (!active()) return;
      if (verified.uid != principal.uid ||
          verified.role != principal.role ||
          incoming.principal.uid != principal.uid ||
          incoming.principal.role != principal.role ||
          incoming.contributorUid != filter) {
        session.rejectAuthorization('scope-changed');
        return;
      }
      profile = more ? prior!.append(incoming) : incoming;
    } catch (error) {
      if (_disposed ||
          requestGeneration != null && requestGeneration != _generation) {
        return;
      }
      final code = switch (error) {
        DatasetApiFailure(:final code) => code,
        SessionFailure(:final code) => code,
        _ => 'profile-unavailable',
      };
      if ({'session-expired', 'forbidden'}.contains(code)) {
        session.rejectAuthorization(code);
      } else {
        errorCode = code;
        // A failed next page cannot discard an already complete visible page,
        // and old Owner data must never reappear after a role/account change.
        if (session.phase == SessionPhase.authorized &&
            prior?.principal.uid == session.principal?.uid &&
            prior?.principal.role == session.principal?.role) {
          profile = prior;
        }
      }
    } finally {
      loading = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    profile = null;
    session.removeListener(_sessionChanged);
    super.dispose();
  }
}
