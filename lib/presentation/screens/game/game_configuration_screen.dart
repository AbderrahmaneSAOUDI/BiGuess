import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/models/difficulty.dart';
import '../../../domain/models/entitlement.dart';
import '../../../domain/models/game_setup.dart';
import '../../../providers/entitlement_provider.dart';
import '../../../providers/game_session_controller.dart';
import '../../../providers/gameplay_network_gate.dart';
import '../../../providers/pack_download_controller.dart';
import '../../../providers/catalog_controller.dart';
import '../../controllers/update_controller.dart';
import '../../../providers/game_settings_controller.dart';
import '../../../providers/topic_pack_providers.dart';
import 'game_screen.dart';

/// Short setup step for the selected locally available Pack.
class GameConfigurationScreen extends ConsumerStatefulWidget {
  final String topicName;
  final String packName;

  const GameConfigurationScreen({
    super.key,
    required this.topicName,
    required this.packName,
  });

  @override
  ConsumerState<GameConfigurationScreen> createState() =>
      _GameConfigurationScreenState();
}

class _GameConfigurationScreenState
    extends ConsumerState<GameConfigurationScreen> {
  final _roundsController = TextEditingController(
    text: '${Entitlement.freeRoundLimit}',
  );
  Difficulty _difficulty = Difficulty.easy;
  bool _starting = false;
  bool _enteredSession = false;
  String? _startError;

  ({String topic, String pack}) get _key =>
      (topic: widget.topicName, pack: widget.packName);

  GameSetup get _setup => GameSetup(
    maximumDifficulty: _difficulty,
    rounds: int.tryParse(_roundsController.text.trim()) ?? 0,
  );

  @override
  void dispose() {
    _roundsController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_starting || ref.read(gameplayPreparingProvider)) return;
    final setup = _setup;
    ref.invalidate(gameSetupContentProvider(_key));
    var content = ref.read(gameSetupContentProvider(_key));
    if (setup.validate(
          entitlement: ref.read(entitlementProvider),
          content: content,
        ) !=
        null) {
      return;
    }
    setState(() {
      _starting = true;
      _startError = null;
    });
    final preparing = ref.read(gameplayPreparingProvider.notifier);
    preparing.state = true;
    try {
      // End earlier explicit content requests before the offline Start boundary.
      final stopped = ref
          .read(packDownloadsProvider.notifier)
          .stopForGameplay();
      ref.invalidate(publicCatalogRepositoryProvider);
      ref.read(publicCatalogRepositoryProvider);
      ref.invalidate(packDownloadRepositoryProvider);
      ref.read(packDownloadRepositoryProvider);
      await Future.wait([
        stopped,
        ref.read(updateControllerProvider.notifier).pauseForGameplay(),
      ]);
      if (!mounted) return;
      final runtime = ref.read(localContentRuntimeProvider);
      if (runtime?.usesSqlite == true) {
        content = await runtime!.verifyForPlay(
          topicId: content!.topic.id,
          packIds: content.packs.map((pack) => pack.id),
        );
      }
      if (!mounted) return;
      // The legacy migration/rollback path remains until T47. The installed
      // runtime above always supplies freshly verified private generations.
      final entitlement = ref.read(entitlementProvider);
      final snapshot = setup.freeze(entitlement: entitlement, content: content);
      final session = ref.read(gameSessionProvider.notifier);
      session.configure(snapshot.configuration);
      session.start(
        topic: snapshot.topic,
        installedPacks: snapshot.packs,
        installedCards: snapshot.cards,
      );
      _enteredSession = true;
      ref.read(showCharacterNameHintProvider.notifier).set(false);
      FocusManager.instance.primaryFocus?.unfocus();
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (context) => GameScreen(
            topicName: widget.topicName,
            packName: widget.packName,
            useSession: true,
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _startError =
              'Installed Pack files could not be verified. Return to Packs to choose another Pack.';
        });
      }
    } finally {
      if (preparing.mounted) preparing.state = false;
      if (mounted && !_enteredSession) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entitlement = ref.watch(entitlementProvider);
    final content = ref.watch(gameSetupContentProvider(_key));
    final setup = _setup;
    final error = setup.validate(entitlement: entitlement, content: content);
    final errorText = switch (error) {
      GameSetupError.invalidRounds => 'Enter a positive whole number.',
      GameSetupError.freeRoundLimit => 'Free games allow up to 10 rounds.',
      GameSetupError.packNotInstalled =>
        'Download at least one Pack before starting.',
      GameSetupError.emptyEligiblePool =>
        'No cards match this difficulty. Choose a higher difficulty or another Pack.',
      null => null,
    };
    final roundsError =
        error == GameSetupError.invalidRounds ||
        error == GameSetupError.freeRoundLimit;
    final eligibleCount = setup
        .eligibleCards(content?.installedCards ?? [])
        .length;

    return Scaffold(
      appBar: AppBar(title: const Text('Game Setup')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.topicName,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.packName.replaceAll('_', ' '),
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 28),
                  DropdownButtonFormField<Difficulty>(
                    initialValue: _difficulty,
                    decoration: const InputDecoration(labelText: 'Difficulty'),
                    items: const [
                      DropdownMenuItem(
                        value: Difficulty.easy,
                        child: Text('Easy'),
                      ),
                      DropdownMenuItem(
                        value: Difficulty.medium,
                        child: Text('Medium'),
                      ),
                      DropdownMenuItem(
                        value: Difficulty.hard,
                        child: Text('Hard'),
                      ),
                    ],
                    onChanged: _starting
                        ? null
                        : (value) => setState(() => _difficulty = value!),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Easy: Easy cards\nMedium: Easy + Medium\nHard: Easy + Medium + Hard',
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _roundsController,
                    enabled: !_starting,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Number of rounds',
                      helperText: entitlement.maxRounds == null
                          ? 'Choose any positive number of rounds.'
                          : '1–10 rounds per game',
                      errorText: roundsError ? errorText : null,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 24),
                  Text('$eligibleCount eligible cards'),
                  if (errorText != null && !roundsError) ...[
                    const SizedBox(height: 8),
                    Text(
                      errorText,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (_startError != null) ...[
                    const SizedBox(height: 16),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _startError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.maybePop(context),
                      child: const Text('Back to Packs'),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: error == null && !_starting ? _start : null,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(
                      _starting ? 'Checking installed Packs…' : 'Start Game',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
