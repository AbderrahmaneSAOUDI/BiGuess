import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/pack_tombstone.dart';
import '../domain/models/game_session.dart';
import 'game_session_controller.dart';
import 'topic_pack_providers.dart';

final packRetirementsProvider = Provider<List<PackRetirement>>((ref) {
  ref.watch(contentRepositoryProvider);
  return ref.watch(localContentRuntimeProvider)?.retirements ?? const [];
});

final deletedPackIdsProvider = Provider<Set<String>>(
  (ref) => Set.unmodifiable(
    ref
        .watch(packRetirementsProvider)
        .where((r) => r.isAuthoritative)
        .map((r) => r.packId),
  ),
);

/// Holds verified generation leases through active rounds/completion/replay.
/// Exit releases leases; subsequent Home cleanup can reclaim retired bytes.
final playbackLeaseLifecycleProvider = Provider<void>((ref) {
  final runtime = ref.watch(localContentRuntimeProvider);
  if (runtime == null) return;
  ref.listen(gameSessionProvider, (previous, next) {
    if (next.phase == GameSessionPhase.home ||
        next.phase == GameSessionPhase.exited) {
      unawaited(runtime.releasePlayback());
    }
  });
  ref.onDispose(() => unawaited(runtime.releasePlayback()));
});
