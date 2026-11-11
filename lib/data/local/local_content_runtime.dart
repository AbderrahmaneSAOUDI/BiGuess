import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/models/topic.dart';
import '../../domain/repositories/content_repository.dart';
import '../repositories/legacy_manifest_content_repository.dart';
import '../repositories/sqlite_content_repository.dart';
import 'local_pack_store.dart';

/// Bridge from committed private generations to the screen API at startup and
/// after an explicit verified installation.
/// The separate SQLite projection is disposable metadata, never installation
/// authority. No catalog/sync database or active game is modified here.
final class LocalContentRuntime {
  static const databaseName = 'biguess_installed_content.sqlite';
  ContentRepository _repository;
  ContentRepository get repository => _repository;
  final LocalPackStore? store;
  final Object? failure;

  LocalContentRuntime._(this._repository, this.store, [this.failure]);

  bool get usesSqlite => repository is SqliteContentRepository;

  static Future<LocalContentRuntime> open({
    Directory? supportDirectory,
    File? importFile,
    bool useLegacy = false,
  }) async {
    final legacy = LegacyManifestContentRepository();
    if (useLegacy) return LocalContentRuntime._(legacy, null);
    SqliteContentRepository? sql;
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
      // An explicit developer seed is optional on subsequent offline restarts.
      if (importFile != null && await importFile.exists()) {
        await store.install(importFile);
      }
      final installed = await store.readAllInstalled();
      if (installed.isEmpty) return LocalContentRuntime._(legacy, store);
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
      return LocalContentRuntime._(sql, store);
    } catch (error) {
      sql?.close();
      // Never delete/repair source generations or a failed database to recover.
      return LocalContentRuntime._(legacy, null, error);
    }
  }

  void close() {
    final local = repository;
    if (local is SqliteContentRepository) local.close();
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
    _repository = next.repository;
    if (previous is SqliteContentRepository) previous.close();
  }
}
