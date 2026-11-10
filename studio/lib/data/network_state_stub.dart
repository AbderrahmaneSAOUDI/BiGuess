import 'dart:async';

class BrowserNetwork {
  bool get online => true;
  Stream<bool> get changes => const Stream.empty();
  void dispose() {}
}
