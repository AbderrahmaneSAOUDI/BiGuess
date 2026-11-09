import 'dart:async';

import 'package:flutter/foundation.dart';

abstract interface class StudioIdentity {
  Stream<String?> get changes;
  Future<void> restore();
  Future<String?> token({bool refresh = false});
  Future<void> popup();
  Future<void> redirect();
  Future<void> signOut();
}

class SessionFailure implements Exception {
  const SessionFailure(this.code);
  final String code;
}

class StudioPrincipal {
  const StudioPrincipal(this.uid, this.email, this.role);
  final String uid;
  final String email;
  final String role;
}

abstract interface class StudioAuthorization {
  Future<StudioPrincipal> lookup(String token);
}

enum SessionPhase {
  restoring,
  signedOut,
  checking,
  authorized,
  denied,
  unavailable,
  error,
}

/// Authorization is never persisted. Every restoration/token change requires
/// the Worker; generations prevent late requests restoring a previous account.
class StudioSession extends ChangeNotifier {
  StudioSession(
    this.identity,
    this.authorization, {
    this.recheckInterval = const Duration(minutes: 1),
  });
  final StudioIdentity identity;
  final StudioAuthorization authorization;
  final Duration recheckInterval;
  SessionPhase phase = SessionPhase.restoring;
  StudioPrincipal? principal;
  String? errorCode;
  StreamSubscription<String?>? _subscription;
  Timer? _timer;
  int _generation = 0;
  bool _disposed = false;
  bool _suspended = false;
  bool _signingOut = false;
  bool _signedOutByUser = false;

  void _clear(SessionPhase value, [String? code]) {
    principal = null;
    phase = value;
    errorCode = code;
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    try {
      await identity.restore().timeout(const Duration(seconds: 20));
    } catch (error) {
      _clear(SessionPhase.error, _code(error));
    }
    if (_disposed) return;
    // Keep observing after redirect/storage failures so a subsequent popup or
    // restored session can recover without reloading the app.
    _subscription = identity.changes.listen(
      (uid) {
        if (_suspended || _signingOut || _signedOutByUser) return;
        if (uid == null) {
          _generation++;
          if (phase != SessionPhase.error) _clear(SessionPhase.signedOut);
        } else {
          unawaited(validate());
        }
      },
      onError: (_) {
        _generation++;
        _clear(SessionPhase.error, 'session-expired');
      },
    );
    _timer = Timer.periodic(recheckInterval, (_) {
      if (!_suspended && phase == SessionPhase.authorized) {
        unawaited(validate(refresh: true));
      }
    });
  }

  Future<void> validate({bool refresh = false}) async {
    if (_disposed || _signingOut) return;
    if (_signedOutByUser) {
      _clear(SessionPhase.signedOut);
      return;
    }
    final generation = ++_generation;
    _clear(SessionPhase.checking);
    try {
      final token = await identity
          .token(refresh: refresh)
          .timeout(const Duration(seconds: 15));
      if (token == null) throw const SessionFailure('session-expired');
      final result = await authorization
          .lookup(token)
          .timeout(const Duration(seconds: 15));
      if (_disposed || generation != _generation || _suspended) return;
      principal = result;
      phase = SessionPhase.authorized;
      notifyListeners();
    } catch (error) {
      if (_disposed || generation != _generation) return;
      final code = _code(error);
      _clear(switch (code) {
        'forbidden' => SessionPhase.denied,
        'backend-not-configured' => SessionPhase.unavailable,
        _ => SessionPhase.error,
      }, code);
    }
  }

  Future<void> signIn({bool redirect = false}) async {
    if (_disposed || _signingOut) return;
    _signedOutByUser = false;
    final generation = ++_generation;
    _clear(SessionPhase.checking);
    try {
      // Invoke popup directly from the user gesture, without preceding IO.
      if (redirect) {
        await identity.redirect();
      } else {
        await identity.popup();
      }
    } catch (error) {
      if (!_disposed && generation == _generation) {
        _clear(SessionPhase.error, _code(error));
      }
    }
  }

  Future<void> logout() async {
    if (_disposed || _signingOut) return;
    _generation++;
    _signingOut = true;
    _signedOutByUser = true;
    // Clear access immediately, but keep sign-in controls unavailable until
    // Firebase finishes signing out so the two identity operations cannot race.
    _clear(SessionPhase.checking);
    try {
      await identity.signOut().timeout(const Duration(seconds: 15));
      _clear(SessionPhase.signedOut);
    } catch (error) {
      _clear(SessionPhase.error, _code(error));
    } finally {
      _signingOut = false;
    }
  }

  Future<void> switchAccount() async {
    await logout();
    // A second explicit click opens Google so browsers retain user activation.
  }

  void suspend() {
    _suspended = true;
    _generation++;
    _clear(SessionPhase.restoring);
  }

  Future<void> resume() async {
    _suspended = false;
    await validate(refresh: true);
  }

  String _code(Object error) =>
      error is SessionFailure ? error.code : 'network-request-failed';

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
