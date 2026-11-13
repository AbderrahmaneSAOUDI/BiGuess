import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/models/topic.dart';
import '../../domain/models/card.dart';
import '../../domain/models/pack.dart';
import '../../domain/models/game_setup.dart';
import '../../domain/repositories/content_repository.dart';
import '../repositories/legacy_manifest_content_repository.dart';
import '../repositories/sqlite_content_repository.dart';
import 'local_pack_store.dart';
import 'pack_tombstone.dart';

/// Bridge from committed private generations to the screen API at startup and
/// after an explicit verified installation.
/// The separate SQLite projection is disposable metadata, never installation
/// authority. No catalog/sync database or active game is modified here.
final class LocalContentRuntime {
  static const databaseName = 'biguess_installed_content.sqlite';
  ContentRepository _repository;
  ContentRepository get repository => _retirements.isEmpty
      ? _repository
      : _RetirementFallback(
          _repository,
          _retirements.map((r) => r.packId).toSet(),
        );
  final LocalPackStore? store;
  final Object? failure;
  List<PackRetirement> _retirements;
  List<PackRetirement> get retirements => _retirements;
  PackPlaybackLease? _playbackLease;
  Future<void> _releasingPlayback = Future.value();

  LocalContentRuntime._(
    this._repository,
    this.store, [
    this.failure,
    List<PackRetirement> retirements = const [],
  ]) : _retirements = List.unmodifiable(retirements);

  bool get usesSqlite => _repository is SqliteContentRepository;

  static Future<LocalContentRuntime> open({
    Directory? supportDirectory,
    File? importFile,
    bool useLegacy = false,
  }) async {
    final legacy = LegacyManifestContentRepository();
    if (useLegacy) {
      try {
        final directory =
            supportDirectory ?? await getApplicationSupportDirectory();
        final records = await LocalPackStore(
          Directory(p.join(directory.path, 'packs')),
        ).readRetirements();
        return LocalContentRuntime._(legacy, null, null, records);
      } catch (error) {
        return LocalContentRuntime._(
          _RetirementFallback(legacy, const {}, excludeAll: true),
          null,
          error,
        );
      }
    }
    SqliteContentRepository? sql;
    var retirements = <PackRetirement>[];
    var readableManagement = true;
    try {
      final directory =
          supportDirectory ?? await getApplicationSupportDirectory();
      await directory.create(recursive: true);
      final store = LocalPackStore(Directory(p.join(directory.path, 'packs')));
      // Local recovery is bounded and never starts a network request. Failure
      // to remove abandoned bytes must not hide valid installed gameplay.
      try {
        await store.recoverInterruptedDownloads();
      } on FileSystemException {
        // Retry cleanup at the next startup or explicit download.
      }
      try {
        retirements = await store.readRetirements();
      } catch (_) {
        readableManagement = false;
        rethrow;
      }
      // A cold open has no local game; generation leases protect other readers.
      try {
        await store.cleanupRetired();
      } on FileSystemException {
        /* Retry at Home. */
      }
      // An explicit developer seed is optional on subsequent offline restarts.
      if (importFile != null && await importFile.exists()) {
        await store.install(importFile);
        retirements = await store.readRetirements();
      }
      final installed = await store.readAllInstalled();
      final topics = <String, Topic>{};
      for (final local in installed) {
        final topic = local.manifest.topic;
        final previous = topics[topic.id];
        // Display names are labels, not identity. Different Topic or Pack IDs
        // may share a name; only conflicting metadata for the same ID is invalid.
        if (previous != null && previous != topic) {
          throw const FormatException('Conflicting installed Topic metadata');
        }
        topics[topic.id] = topic;
      }
      sql = SqliteContentRepository.open(p.join(directory.path, databaseName));
      sql.replaceInstalledContent(
        topics: topics.values,
        packs: installed.map((local) => local.manifest.pack),
        cards: installed.expand((local) => local.cards),
        projectedAt: DateTime.now().toUtc(),
      );
      return LocalContentRuntime._(sql, store, null, retirements);
    } catch (error) {
      sql?.close();
      // Never delete/repair source generations or a failed database to recover.
      final fallback = useLegacy
          ? (readableManagement && retirements.isEmpty
              ? legacy
              : _RetirementFallback(
                  legacy,
                  retirements.map((r) => r.packId).toSet(),
                  excludeAll: !readableManagement,
                ))
          : _RetirementFallback(legacy, const {}, excludeAll: true);
      return LocalContentRuntime._(fallback, null, error, retirements);
    }
  }

  Future<void> close() async {
    await releasePlayback();
    final local = _repository;
    if (local is SqliteContentRepository) local.close();
  }

  /// Reopen selected immutable private generations at Start. SQLite is a
  /// browsing projection and cannot prove that bytes still exist or are valid.
  Future<GameSetupContent?> verifyForPlay({
    required String topicId,
    required Iterable<String> packIds,
  }) async {
    final localStore = store;
    if (localStore == null) return null;
    final retained = await localStore.retainForSession(packIds);
    if (retained == null) return null;
    try {
      Topic? topic;
      for (final installed in retained.packs) {
        if (installed.manifest.pack.topicId != topicId ||
            installed.manifest.toJson()['provenance']['mode'] !=
                'cleared-test') {
          return null;
        }
        if (topic != null && topic != installed.manifest.topic) return null;
        topic = installed.manifest.topic;
      }
      if (topic == null) return null;
      final content = GameSetupContent.selectedPacks(
        topic: topic,
        packs: retained.packs.map((p) => p.manifest.pack),
        installedCards: retained.packs.expand((p) => p.cards),
      );
      await releasePlayback();
      _playbackLease = retained;
      return content;
    } finally {
      if (!identical(_playbackLease, retained)) await retained.release();
    }
  }

  Future<void> releasePlayback() {
    final lease = _playbackLease;
    _playbackLease = null;
    if (lease != null) {
      final previous = _releasingPlayback;
      _releasingPlayback = () async {
        await previous;
        await lease.release();
      }();
    }
    return _releasingPlayback;
  }

  Future<void> refreshRetirements() async {
    final localStore = store;
    if (localStore == null) throw StateError('Private storage unavailable');
    _retirements = List.unmodifiable(await localStore.readRetirements());
  }

  /// Reproject only committed, verified private generations after an explicit
  /// install. Callers invalidate their repository binding after this completes.
  /// Existing game sessions already own immutable Cards and generation paths.
  Future<void> reloadInstalled() async {
    final localStore = store;
    if (localStore == null) {
      throw StateError('Local Pack storage is unavailable');
    }
    final next = await open(supportDirectory: localStore.root.parent);
    if (next.failure != null || !next.usesSqlite) {
      next.close();
      throw StateError('Installed Pack projection could not be opened');
    }
    final previous = _repository;
    _repository = next._repository;
    _retirements = next.retirements;
    if (previous is SqliteContentRepository) previous.close();
  }
}

/// Failure fallback cannot resurrect a retired ID through bundled content.
class _RetirementFallback implements ContentRepository {
  _RetirementFallback(this.base, this.retired, {this.excludeAll = false});
  final ContentRepository base;
  final Set<String> retired;
  final bool excludeAll;
  @override
  List<Topic> getTopics() => excludeAll
      ? const []
      : List.unmodifiable(
          base.getTopics().where((t) => getPacksForTopic(t.id).isNotEmpty),
        );
  @override
  List<Pack> getPacksForTopic(String id) => excludeAll
      ? const []
      : List.unmodifiable(
          base.getPacksForTopic(id).where((p) => !retired.contains(p.id)),
        );
  @override
  List<Card> getCardsForPack(String id) =>
      excludeAll || retired.contains(id) ? const [] : base.getCardsForPack(id);
  @override
  List<Card>? getInstalledCardsForPack(String id) =>
      excludeAll || retired.contains(id)
      ? null
      : base.getInstalledCardsForPack(id);
}
