import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models/game_session.dart';
import 'game_session_controller.dart';

/// Set before cancelling outstanding content work and verifying local files.
final gameplayPreparingProvider = StateProvider<bool>((ref) => false);

/// Completion/replay remains offline until the explicit Home/exit boundary.
final gameplayNetworkBlockedProvider = Provider<bool>((ref) {
  final phase = ref.watch(gameSessionProvider).phase;
  return ref.watch(gameplayPreparingProvider) ||
      phase == GameSessionPhase.active ||
      phase == GameSessionPhase.completed;
});
