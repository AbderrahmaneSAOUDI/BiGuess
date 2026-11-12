import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import '../../../core/constants/app_constants.dart';
import '../../../domain/models/update_state.dart';
import '../../../providers/topic_pack_providers.dart';
import '../../../providers/pack_update_controller.dart';
import '../../../providers/local_pack_management_providers.dart';
import '../packs/installed_packs_screen.dart';
import '../../../providers/catalog_controller.dart';
import '../../widgets/common/catalog_status.dart';
import '../../../providers/theme_controller.dart';
import '../../controllers/update_controller.dart';
import '../../widgets/animations/animated_glass_app_bar_background.dart';
import '../../widgets/animations/interactive_scale_card.dart';
import '../../widgets/common/biguess_logo_button.dart';
import '../../widgets/common/glass_icon_button.dart';
import '../../dialogs/info/game_info_dialog.dart';
import '../../dialogs/update/update_dialog.dart';
import '../packs/packs_screen.dart';

/// First screen: Topic selection dashboard (Anime, Geography, Movies…)
class TopicsScreen extends ConsumerStatefulWidget {
  const TopicsScreen({super.key});

  @override
  ConsumerState<TopicsScreen> createState() => _TopicsScreenState();
}

class _TopicsScreenState extends ConsumerState<TopicsScreen> {
  @override
  void initState() {
    super.initState();
    // Own this listener in the Home scope, not the temporary setup override.
    ref.read(playbackLeaseLifecycleProvider);
  }

  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(contentRepositoryProvider);
    final topics = ref.watch(browseTopicsProvider);
    final catalog = ref.watch(catalogBrowseProvider).snapshot;
    final installedDownloads = ref.watch(installedDownloadPacksProvider);
    final retirements = ref.watch(packRetirementsProvider);
    final storageFailure = ref.watch(localContentRuntimeProvider)?.failure;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final themeMode = ref.watch(themeNotifierProvider);

    final topPadding = MediaQuery.paddingOf(context).top + kToolbarHeight + 24;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: _TopicsAppBar(isDark: themeMode == ThemeMode.dark),
      body: Stack(
        children: [
          // Ambient radial background gradient
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, -0.4),
                  radius: 1.3,
                  colors: isDark
                      ? [
                          theme.colorScheme.surfaceContainerHighest.withValues(
                            alpha: 0.35,
                          ),
                          theme.scaffoldBackgroundColor,
                        ]
                      : [
                          theme.colorScheme.primaryContainer.withValues(
                            alpha: 0.25,
                          ),
                          theme.scaffoldBackgroundColor,
                        ],
                ),
              ),
            ),
          ),
          AnimationLimiter(
            child: ListView.builder(
              padding: EdgeInsets.fromLTRB(20, topPadding, 20, 32),
              itemCount: topics.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const CatalogStatus(),
                      if (storageFailure != null)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 16),
                          child: Text(
                            'Downloaded content could not be opened. Saved files were kept. Restart the app or free some storage and try again.',
                          ),
                        ),
                      if (installedDownloads.isNotEmpty ||
                          retirements.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: OutlinedButton.icon(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const InstalledPacksScreen(),
                              ),
                            ),
                            icon: const Icon(Icons.inventory_2_outlined),
                            label: const Text('Manage installed Packs'),
                          ),
                        ),
                    ],
                  );
                }
                final browsing = topics[index - 1];
                final selectedTopic = browsing.topic;
                final topic = selectedTopic.name;
                final packs = repository.getPacksForTopic(selectedTopic.id);
                final localIds = packs.map((p) => p.id).toSet();
                final additionalOnline =
                    catalog
                        ?.packsForTopic(selectedTopic.id)
                        .where((p) => !localIds.contains(p.id))
                        .length ??
                    0;
                final totalAssets = packs.fold<int>(
                  0,
                  (total, pack) =>
                      total + repository.getCardsForPack(pack.id).length,
                );
                final accentColor = AppConstants.getTopicColor(topic);
                final icon = AppConstants.getTopicIcon(topic);

                return AnimationConfiguration.staggeredList(
                  position: index - 1,
                  duration: const Duration(milliseconds: 700),
                  child: SlideAnimation(
                    verticalOffset: 60.0,
                    curve: Curves.easeOutCubic,
                    child: FadeInAnimation(
                      duration: const Duration(milliseconds: 700),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 18.0),
                        child: _TopicCard(
                          key: ValueKey('topic-${selectedTopic.id}'),
                          topic: topic,
                          icon: icon,
                          accent: accentColor,
                          packCount: packs.length,
                          totalAssets: totalAssets,
                          packLabel: browsing.local
                              ? null
                              : browsing.unavailableOnline
                              ? 'Unavailable online'
                              : catalog?.packsCheckedAt.containsKey(
                                      selectedTopic.id,
                                    ) ==
                                    true
                              ? '${catalog!.packsForTopic(selectedTopic.id).length} online packs'
                              : 'Online topic',
                          itemLabel: browsing.local
                              ? null
                              : catalog?.packsCheckedAt.containsKey(
                                      selectedTopic.id,
                                    ) ==
                                    true
                              ? '${catalog!.packsForTopic(selectedTopic.id).fold<int>(0, (sum, p) => sum + p.cardCount)} catalog items'
                              : 'Packs not loaded',
                          catalogLabel:
                              browsing.local && browsing.unavailableOnline
                              ? 'Unavailable online'
                              : browsing.local && additionalOnline > 0
                              ? '+$additionalOnline online packs'
                              : null,
                          onTap: () => _navigateToPacks(
                            context,
                            topic,
                            selectedTopic.id,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _navigateToPacks(BuildContext context, String topic, String topicId) {
    Navigator.push(
      context,
      PageRouteBuilder<void>(
        pageBuilder: (context, animation, secondaryAnimation) =>
            PacksScreen(topicName: topic, topicId: topicId),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            ),
            child: SlideTransition(
              position:
                  Tween<Offset>(
                    begin: const Offset(0.05, 0),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutCubic,
                    ),
                  ),
              child: child,
            ),
          );
        },
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }
}

/// Premium topic card with gradient accent, icon, and metadata
class _TopicCard extends StatelessWidget {
  final String topic;
  final IconData icon;
  final Color accent;
  final int packCount;
  final int totalAssets;
  final VoidCallback onTap;
  final String? packLabel, itemLabel, catalogLabel;

  const _TopicCard({
    super.key,
    required this.topic,
    required this.icon,
    required this.accent,
    required this.packCount,
    required this.totalAssets,
    required this.onTap,
    this.packLabel,
    this.itemLabel,
    this.catalogLabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return InteractiveScaleCard(
      onTap: onTap,
      glowColor: theme.colorScheme.primary,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        constraints: const BoxConstraints(minHeight: 130),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.surface,
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            ],
          ),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
            width: 1.2,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          child: Row(
            children: [
              // Clean icon circle
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : Colors.black.withValues(alpha: 0.04),
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.12)
                        : Colors.black.withValues(alpha: 0.08),
                    width: 1.2,
                  ),
                ),
                child: Icon(icon, size: 28, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 20),
              // Text content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      topic,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: theme.colorScheme.onSurface,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 10,
                      runSpacing: 6,
                      children: [
                        _MetadataChip(
                          icon: Icons.folder_rounded,
                          label: packLabel ?? '$packCount packs',
                        ),
                        _MetadataChip(
                          icon: Icons.image_rounded,
                          label: itemLabel ?? '$totalAssets items',
                        ),
                        if (catalogLabel != null)
                          _MetadataChip(
                            icon: Icons.cloud_off_rounded,
                            label: catalogLabel!,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              // Arrow
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetadataChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MetadataChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.04),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.05),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 13,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Glassmorphic AppBar for the Topics screen
class _TopicsAppBar extends ConsumerWidget implements PreferredSizeWidget {
  final bool isDark;

  const _TopicsAppBar({required this.isDark});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final updateState = ref.watch(updateControllerProvider);

    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      flexibleSpace: const AnimatedGlassAppBarBackground(),
      leading: const Padding(
        padding: EdgeInsets.only(left: 12.0),
        child: BiGuessLogoButton(),
      ),
      title: Text(
        AppConstants.appTitle,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          letterSpacing: -0.2,
          color: theme.colorScheme.onSurface,
          shadows: [
            Shadow(
              color: isDark
                  ? Colors.black.withValues(alpha: 0.5)
                  : Colors.white.withValues(alpha: 0.7),
              blurRadius: 4,
            ),
          ],
        ),
      ),
      actions: [
        if (updateState is UpdateAvailable)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3.0),
            child: GlassIconButton.icon(
              iconData: Icons.system_update_rounded,
              iconColor: Colors.amber,
              glowColor: Colors.amber,
              tooltip: 'Update v${updateState.latestVersion} Available',
              onPressed: () => UpdateDialog.show(context),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3.0),
          child: GlassIconButton.icon(
            iconData: Icons.settings_rounded,
            tooltip: 'Settings',
            onPressed: () {
              GameInfoDialog.show(context, initialTab: GameInfoTab.settings);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3.0),
          child: GlassIconButton.icon(
            iconData: Icons.info_outline_rounded,
            tooltip: 'Rules & About',
            onPressed: () {
              GameInfoDialog.show(context, initialTab: GameInfoTab.howToPlay);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 3.0, right: 12.0),
          child: GlassIconButton(
            tooltip: isDark ? 'Switch to Light Mode' : 'Switch to Dark Mode',
            onPressed: () =>
                ref.read(themeNotifierProvider.notifier).toggleTheme(),
            icon: AnimatedRotation(
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeOutBack,
              turns: isDark ? 0.5 : 0,
              child: AnimatedScale(
                duration: const Duration(milliseconds: 300),
                scale: isDark ? 1.15 : 1.0,
                child: Icon(
                  isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                  size: 20,
                  color: isDark ? Colors.amberAccent : Colors.orangeAccent,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
