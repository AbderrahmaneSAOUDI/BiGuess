import 'package:biguess_studio/data/offline_access_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'offline access needs an affirmative same-tab online readiness marker',
    () {
      final markers = <String>{};
      final policy = OfflineAccessPolicy(
        readMarker: markers.contains,
        writeMarker: markers.add,
        removeMarker: markers.remove,
      );
      expect(policy.denied('policy-ready-project', 'a'), isTrue);
      policy.allow('policy-ready-project', 'a');
      expect(markers.single, startsWith('biguess-studio-offline-ready:'));
      expect(policy.denied('policy-ready-project', 'a'), isFalse);
      final reopened = OfflineAccessPolicy(
        readMarker: markers.contains,
        writeMarker: markers.add,
        removeMarker: markers.remove,
      );
      expect(reopened.denied('policy-ready-project', 'a'), isFalse);
      expect(reopened.denied('policy-ready-project', 'b'), isTrue);
      expect(reopened.denied('different-project', 'a'), isTrue);
    },
  );

  test(
    'denial removes readiness without allocating quota and fences immediately',
    () {
      final markers = <String>{};
      var writesBlocked = false;
      final policy = OfflineAccessPolicy(
        readMarker: markers.contains,
        writeMarker: (key) {
          if (writesBlocked) throw StateError('quota');
          markers.add(key);
        },
        removeMarker: markers.remove,
      );
      policy.allow('policy-quota-project', 'a');
      expect(policy.denied('policy-quota-project', 'a'), isFalse);
      writesBlocked = true;
      policy.deny('policy-quota-project', 'a');
      expect(markers, isEmpty);
      expect(policy.denied('policy-quota-project', 'a'), isTrue);
      policy.allow('policy-quota-project', 'a');
      expect(policy.denied('policy-quota-project', 'a'), isTrue);
      writesBlocked = false;
      policy.allow('policy-quota-project', 'a');
      expect(policy.denied('policy-quota-project', 'a'), isFalse);
    },
  );

  test('blocked reads, removals and same-value writes fail closed', () {
    final markers = <String>{};
    final ready = OfflineAccessPolicy(
      readMarker: markers.contains,
      writeMarker: markers.add,
      removeMarker: markers.remove,
    );
    ready.allow('policy-blocked-project', 'a');
    final unreadable = OfflineAccessPolicy(
      readMarker: (_) => throw StateError('blocked'),
      writeMarker: markers.add,
      removeMarker: markers.remove,
    );
    expect(unreadable.denied('policy-blocked-project', 'a'), isTrue);
    ready.allow('policy-blocked-project', 'a');
    final blocked = OfflineAccessPolicy(
      readMarker: markers.contains,
      writeMarker: (_) => throw StateError('blocked'),
      removeMarker: (_) => throw StateError('blocked'),
    );
    blocked.deny('policy-blocked-project', 'a');
    expect(markers, hasLength(1));
    expect(blocked.denied('policy-blocked-project', 'a'), isTrue);
    // Successful online recovery clears the process fence. A subsequent policy
    // with reads but no writes still rejects the retained affirmative marker.
    ready.allow('policy-blocked-project', 'a');
    expect(blocked.denied('policy-blocked-project', 'a'), isTrue);
    blocked.allow('policy-blocked-project', 'a');
    expect(blocked.denied('policy-blocked-project', 'a'), isTrue);
    ready.allow('policy-blocked-project', 'a');
    expect(ready.denied('policy-blocked-project', 'a'), isFalse);
  });
}
