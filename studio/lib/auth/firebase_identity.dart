import 'package:firebase_auth/firebase_auth.dart';

import 'studio_session.dart';

class FirebaseIdentity implements StudioIdentity {
  FirebaseIdentity(this.auth);
  final FirebaseAuth auth;
  GoogleAuthProvider get _provider =>
      GoogleAuthProvider()..setCustomParameters({'prompt': 'select_account'});

  Future<T> _call<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on FirebaseAuthException catch (error) {
      throw SessionFailure(error.code);
    }
  }

  @override
  Stream<String?> get changes => auth.idTokenChanges().map((user) => user?.uid);
  @override
  Future<void> restore() => _call(() async {
    await auth.setPersistence(Persistence.SESSION);
    await auth.getRedirectResult();
  });
  @override
  Future<String?> token({bool refresh = false}) =>
      _call(() async => auth.currentUser?.getIdToken(refresh));
  @override
  Future<void> popup() => _call(() async {
    await auth.signInWithPopup(_provider);
  });
  @override
  Future<void> redirect() => _call(() => auth.signInWithRedirect(_provider));
  @override
  Future<void> signOut() => _call(auth.signOut);
}
