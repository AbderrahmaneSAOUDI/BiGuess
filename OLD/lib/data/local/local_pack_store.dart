import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/models/card.dart';
import '../../domain/models/entitlement.dart';
import 'local_pack_file.dart';
import 'private_pack_images.dart';
import 'pack_tombstone.dart';

/// An immutable installed revision. Its directory remains available to readers
/// after an update, so existing snapshots can finish using their original files.
final class InstalledLocalPack {
  final LocalPackManifest manifest;
  final Directory directory;
  late final List<Card> cards;

  InstalledLocalPack._(this.manifest, this.directory) {
    final references = PrivatePackImages.references(manifest, directory);
    cards = List.unmodifiable(
      manifest.cards.map(
        (card) => Card(
          id: card.id,
          packId: card.packId,
          name: card.name,
          imageReference: references[card.imageReference]!,
          difficulty: card.difficulty,
        ),
      ),
    );
  }
}

/// The write boundary, also allowing deterministic storage-failure tests.
/// [activate] must either rename successfully or leave the old pointer intact.
class PackStorageIo {
  const PackStorageIo();

  Future<void> write(File file, List<int> bytes) async {
    await file.writeAsBytes(bytes, flush: true);
  }

  Future<void> activate(File pending, File active) async {
    await pending.rename(active.path);
  }
}

/// A temporary download owns an OS lease until cleanup. Recovery never removes
/// a live transfer, including transfers in another application process.
final class PackDownloadStaging {
  PackDownloadStaging._(this.directory, this._lease);
  final Directory directory;
  final RandomAccessFile _lease;
  bool _released = false;
  static final _active = <String>{};
  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // Startup/next deliberate transfer can retry cleanup once the lease ends.
    } finally {
      _active.remove(directory.path);
      try {
        await _lease.close();
      } on FileSystemException {
        /* Cleanup must not mask the job result. */
      }
    }
  }
}

/// A detached game's shared OS leases keep exact generations readable even
/// when another process retires the installed pointer at its own Home boundary.
final class PackPlaybackLease {
  PackPlaybackLease._(
    this._store,
    Iterable<InstalledLocalPack> packs,
    this._paths,
  ) : packs = List.unmodifiable(packs);
  final LocalPackStore _store;
  final List<InstalledLocalPack> packs;
  final List<String> _paths;
  bool _released = false;
  static final _holds = <String, _PlaybackHold>{};
  Future<void> release() async {
    if (_released) return;
    _released = true;
    var didRelease = false;
    Future<void> releaseHolds() async {
      didRelease = true;
      for (final path in _paths) {
        final held = _holds[path];
        if (held == null || --held.references > 0) continue;
        _holds.remove(path);
        try {
          await held.file.close();
        } on FileSystemException {
          /* Best effort release. */
        }
      }
    }

    // Normal release remains serialized with retain/cleanup. Disposal may race
    // an external deletion or an unavailable support directory; in that case
    // closing held descriptors and dropping local counts must still complete.
    try {
      if (!await _store.root.exists()) {
        await releaseHolds();
      } else {
        await _store._exclusive(releaseHolds);
      }
    } on FileSystemException {
      if (!didRelease) await releaseHolds();
    }
  }
}

final class _PlaybackHold {
  _PlaybackHold(this.file);
  final RandomAccessFile file;
  int references = 1;
}

/// Local file importer, independent of network, UI and the legacy catalog.
///
/// Metadata and images live in one immutable generation. The only commit point
/// is an atomic same-filesystem rename of a flushed pointer file. Never delete
/// the old pointer first. Filesystem errors propagate to the caller.
final class LocalPackStore {
  static final _queues = <String, Future<void>>{};
  final Directory root;
  final PackStorageIo _io;
  final PackImportLimits limits;
  final Entitlement entitlement;

  /// Supply app-private storage. Tests may supply an isolated temporary root.
  LocalPackStore(
    Directory root, {
    PackStorageIo io = const PackStorageIo(),
    this.limits = const PackImportLimits(),
    this.entitlement = const Entitlement.fromEnvironment(),
  }) : root = root.absolute,
       _io = io;

  static Future<LocalPackStore> openDefault({
    Entitlement entitlement = const Entitlement.fromEnvironment(),
  }) async => LocalPackStore(
    Directory(p.join((await getApplicationSupportDirectory()).path, 'packs')),
    entitlement: entitlement,
  );

  /// Import a self-contained .biguesspack ZIP before making it discoverable.
  /// All writers in this process must use the same owning isolate.
  Future<InstalledLocalPack> install(
    File source, {
    void Function()? checkCancelled,
  }) => _exclusive(() async {
    checkCancelled?.call();
    final archive = LocalPackFile.decode(await _readBounded(source), limits);
    final manifest = archive.manifest;
    checkCancelled?.call();

    final deleted = await readTombstone(manifest.pack.id);
    if (deleted != null) throw PackDeletedException();
    final previous = await readInstalled(manifest.pack.id);
    if (previous != null) {
      final old = previous.manifest;
      if (manifest.pack.topicId != old.pack.topicId ||
          manifest.pack.revision < old.pack.revision ||
          (manifest.pack.revision == old.pack.revision &&
              manifest.digest != old.digest)) {
        throw const FormatException('Conflicting or older Pack revision');
      }
      if (manifest.digest == old.digest) {
        checkCancelled?.call();
        return previous;
      }
    }
    final cardIds = manifest.cards.map((card) => card.id).toSet();
    final installedPacks = await readAllInstalled();
    // Counting and activation share the writer lock. Revisions and retries of
    // an existing Pack do not consume a new slot.
    if (previous == null && !entitlement.allowsNewPack(installedPacks.length)) {
      throw StateError('Free storage allows up to 5 downloaded Packs');
    }
    for (final installed in installedPacks) {
      if (installed.manifest.pack.id != manifest.pack.id &&
          installed.manifest.topic.id == manifest.topic.id &&
          installed.manifest.topic != manifest.topic) {
        throw const FormatException('Conflicting installed Topic metadata');
      }
      if (installed.manifest.pack.id != manifest.pack.id &&
          installed.cards.any((card) => cardIds.contains(card.id))) {
        throw const FormatException('Card ID belongs to another Pack');
      }
    }

    final packDirectory = _packDirectory(manifest.pack.id);
    await packDirectory.create(recursive: true);
    await _recoverPendingGeneration(packDirectory, 2);
    if (await File(p.join(packDirectory.path, 'active.pending')).exists()) {
      throw FileSystemException(
        'Interrupted activation cleanup failed',
        packDirectory.path,
      );
    }
    // A killed writer never activated staging. Recover under the writer lock.
    await for (final entry in packDirectory.list(followLinks: false)) {
      if (entry is Directory && p.basename(entry.path).startsWith('staging-')) {
        await entry.delete(recursive: true);
      }
    }
    checkCancelled?.call();
    var staged = await packDirectory.createTemp('staging-');
    final pending = File(p.join(packDirectory.path, 'active.pending'));
    var activated = false;
    try {
      await _io.write(
        File(p.join(staged.path, PrivatePackImages.fileName)),
        PrivatePackImages.encode(manifest, archive.objects),
      );
      checkCancelled?.call();
      await PrivatePackImages.verify(manifest, staged);
      final metadata = File(p.join(staged.path, 'manifest.json'));
      await _io.write(metadata, manifest.metadataBytes);
      if (sha256.convert(await _readBounded(metadata)).toString() !=
          manifest.digest) {
        throw const FormatException('Staged metadata integrity check failed');
      }
      checkCancelled?.call();
      final name = p
          .basename(staged.path)
          .replaceFirst('staging-', 'generation-');
      // Reserve the reader lease inode before activation, while installation
      // already requires writable storage. Starting an installed game then
      // opens it read-only rather than allocating a file on a full disk.
      await File(p.join(staged.path, '.playback.lock')).create();
      // Persist the intended generation before the directory rename. A killed
      // writer leaves enough evidence to reclaim an unactivated generation.
      await _io.write(pending, utf8.encode(name));
      if (utf8.decode(await _readBounded(pending, limit: 128)) != name) {
        throw const FormatException('Staged pointer integrity check failed');
      }
      staged = await staged.rename(p.join(packDirectory.path, name));
      final result = InstalledLocalPack._(manifest, staged);
      // Cancellation is effective until the commit starts. Once the atomic
      // pointer rename begins, completion wins and must be reported as installed.
      checkCancelled?.call();
      await _io.activate(pending, File(p.join(packDirectory.path, 'active')));
      activated = true;
      return result;
    } finally {
      if (!activated) {
        // Best effort rollback: cleanup must not mask the original failure.
        try {
          if (await staged.exists()) await staged.delete(recursive: true);
          if (await pending.exists()) await pending.delete();
        } on FileSystemException {
          // An interrupted cleanup is harmless: the active pointer is intact.
        }
      }
    }
  });

  /// Create staging and acquire its lease while recovery is excluded.
  Future<PackDownloadStaging> createDownloadStaging() => _exclusive(() async {
    final directory = await Directory(
      await root.resolveSymbolicLinks(),
    ).createTemp('download-');
    RandomAccessFile? lease;
    try {
      lease = await File(
        p.join(directory.path, '.lease'),
      ).open(mode: FileMode.append);
      await lease.lock(FileLock.exclusive);
      PackDownloadStaging._active.add(directory.path);
      return PackDownloadStaging._(directory, lease);
    } catch (_) {
      await lease?.close();
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        /* Retry on recovery. */
      }
      rethrow;
    }
  });

  /// Remove a bounded number of owned abandoned temporary entries. This is local
  /// IO only; it never restarts network or removes previously active generations.
  Future<int> recoverInterruptedDownloads({
    int maxEntries = 8,
  }) => _exclusive(() async {
    if (maxEntries < 1 || maxEntries > 64) {
      throw ArgumentError.value(maxEntries);
    }
    var removed = 0;
    await for (final entry in root.list(followLinks: false)) {
      if (removed >= maxEntries) break;
      if (entry is File && p.basename(entry.path) == 'tombstones.pending') {
        try {
          await entry.delete();
          removed++;
        } on FileSystemException {
          /* Retry later. */
        }
        continue;
      }
      if (entry is! Directory) continue;
      final name = p.basename(entry.path);
      if (RegExp(r'^download-[A-Za-z0-9]+$').hasMatch(name)) {
        if (PackDownloadStaging._active.contains(
          await entry.resolveSymbolicLinks(),
        )) {
          continue;
        }
        RandomAccessFile? lease;
        try {
          lease = await File(
            p.join(entry.path, '.lease'),
          ).open(mode: FileMode.append);
          await lease.lock(FileLock.exclusive);
          await entry.delete(recursive: true);
          removed++;
        } on FileSystemException {
          // A live transfer holds the nonblocking lease, or cleanup cannot run.
        } finally {
          await lease?.close();
        }
      } else if (RegExp(r'^[a-f0-9]{64}$').hasMatch(name)) {
        removed += await _recoverPendingGeneration(entry, maxEntries - removed);
        await for (final temporary in entry.list(followLinks: false)) {
          if (removed >= maxEntries) break;
          final child = p.basename(temporary.path);
          if ((temporary is Directory &&
                  RegExp(r'^staging-[A-Za-z0-9]+$').hasMatch(child)) ||
              (temporary is File && child == 'remove.pending')) {
            try {
              await temporary.delete(recursive: true);
              removed++;
            } on FileSystemException {
              /* Best effort. */
            }
          }
        }
      }
    }
    return removed;
  });

  /// A pending pointer exists only before the atomic commit. Reclaim its
  /// never-activated target first; retain the pointer if budget or IO prevents
  /// completing cleanup, so a later pass can safely finish the operation.
  Future<int> _recoverPendingGeneration(Directory pack, int budget) async {
    if (budget < 1) return 0;
    final pending = File(p.join(pack.path, 'active.pending'));
    if (!await pending.exists()) return 0;
    var removed = 0;
    try {
      final String target;
      try {
        target = utf8.decode(await _readBounded(pending, limit: 128));
      } on FormatException {
        // New writers verify pending bytes before renaming staging. Malformed
        // pending bytes cannot refer to a renamed generation.
        await pending.delete();
        return 1;
      }
      final active = File(p.join(pack.path, 'active'));
      final String? activeName;
      try {
        if (await active.exists()) {
          final pointer = utf8.decode(
            await _readBounded(active, limit: 64 * 1024),
          );
          if (pointer.startsWith('{')) {
            final removed = PackRetirement.fromJson(
              LocalPackManifest.object(jsonDecode(pointer)),
            );
            if (removed.isAuthoritative ||
                p.basename(_packDirectory(removed.packId).path) !=
                    p.basename(pack.path)) {
              return 0;
            }
            activeName = null;
          } else {
            activeName = pointer;
          }
        } else {
          activeName = null;
        }
      } on FormatException {
        // Uncertain active identity: retain the generation and its evidence.
        return 0;
      }
      if (activeName != null &&
          !RegExp(r'^generation-[A-Za-z0-9]+$').hasMatch(activeName)) {
        return 0;
      }
      if (RegExp(r'^generation-[A-Za-z0-9]+$').hasMatch(target) &&
          target != activeName) {
        final generation = Directory(p.join(pack.path, target));
        if (await FileSystemEntity.type(generation.path, followLinks: false) ==
            FileSystemEntityType.directory) {
          await generation.delete(recursive: true);
          removed++;
          if (removed >= budget) return removed;
        }
      }
      await pending.delete();
      removed++;
    } on FileSystemException {
      /* Preserve pending evidence for a later pass. */
    }
    return removed;
  }

  /// Reopens and verifies the committed generation, including its images.
  /// Unreferenced directories and pending pointers are never considered installed.
  Future<InstalledLocalPack?> readInstalled(String packId) async {
    if ((await _readTombstoneLedger()).containsKey(packId)) return null;
    final installed = await _readDirectory(_packDirectory(packId));
    if (installed != null && installed.manifest.pack.id != packId) {
      throw const FormatException('Installed Pack ID does not match directory');
    }
    return installed;
  }

  Future<List<InstalledLocalPack>> readAllInstalled() async {
    if (!await root.exists()) return const [];
    final installed = <InstalledLocalPack>[];
    final tombstones = await _readTombstoneLedger();
    final retiredDirectories = {
      for (final id in tombstones.keys) p.basename(_packDirectory(id).path),
    };
    await for (final entry in root.list(followLinks: false)) {
      if (entry is Directory &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(p.basename(entry.path))) {
        if (retiredDirectories.contains(p.basename(entry.path))) {
          continue;
        }
        final pack = await _readDirectory(entry);
        if (pack != null) {
          if (p.basename(_packDirectory(pack.manifest.pack.id).path) !=
              p.basename(entry.path)) {
            throw const FormatException(
              'Installed Pack ID does not match directory',
            );
          }
          installed.add(pack);
        }
      }
    }
    installed.sort((a, b) => a.manifest.pack.id.compareTo(b.manifest.pack.id));
    return List.unmodifiable(installed);
  }

  Future<InstalledLocalPack?> _readDirectory(Directory packDirectory) async {
    final active = File(p.join(packDirectory.path, 'active'));
    if (!await active.exists()) return null;
    final pointer = utf8.decode(await _readBounded(active, limit: 64 * 1024));
    if (pointer.startsWith('{')) {
      final removed = PackRetirement.fromJson(
        LocalPackManifest.object(jsonDecode(pointer)),
      );
      if (removed.isAuthoritative ||
          p.basename(_packDirectory(removed.packId).path) !=
              p.basename(packDirectory.path)) {
        throw const FormatException('Invalid local removal pointer');
      }
      return null;
    }
    final name = pointer;
    if (!RegExp(r'^generation-[A-Za-z0-9]+$').hasMatch(name)) {
      throw const FormatException('Invalid installed generation pointer');
    }
    final directory = Directory(p.join(packDirectory.path, name));
    final metadata = File(p.join(directory.path, 'manifest.json'));
    final bytes = await _readBounded(metadata);
    final manifest = LocalPackManifest.fromJson(
      LocalPackManifest.object(jsonDecode(utf8.decode(bytes))),
    );
    if (sha256.convert(bytes).toString() != manifest.digest) {
      throw const FormatException('Installed metadata integrity check failed');
    }
    await PrivatePackImages.verify(manifest, directory);
    return InstalledLocalPack._(manifest, directory);
  }

  /// A user removal only replaces the active pointer. The old generation is
  /// retained until leased-safe cleanup; the same public Pack can be installed.
  Future<void> removeDownload(
    String packId, {
    required int expectedRevision,
    String? expectedDigest,
    void Function()? checkCancelled,
  }) => _exclusive(() async {
    checkCancelled?.call();
    if ((await _readTombstoneLedger()).containsKey(packId)) {
      throw StateError('Pack was authoritatively deleted');
    }
    final installed = await readInstalled(packId);
    if (installed == null) throw StateError('Pack is no longer installed');
    _expectInstalled(installed, expectedRevision, expectedDigest);
    final record = _retirement(installed);
    final pending = File(p.join(_packDirectory(packId).path, 'remove.pending'));
    try {
      final bytes = utf8.encode(jsonEncode(record.toJson()));
      await _io.write(pending, bytes);
      if (sha256
              .convert(await _readBounded(pending, limit: 64 * 1024))
              .toString() !=
          sha256.convert(bytes).toString()) {
        throw const FormatException('Removal pointer integrity check failed');
      }
      checkCancelled?.call();
      await _io.activate(
        pending,
        File(p.join(_packDirectory(packId).path, 'active')),
      );
    } finally {
      try {
        if (await pending.exists()) await pending.delete();
      } on FileSystemException {
        /* Recovery retries. */
      }
    }
  });

  /// Only a caller that has validated its entire user-requested Home response
  /// supplies deletion evidence. Every CAS is checked before the single commit.
  Future<void> applyTombstones(
    Iterable<PackTombstone> tombstones, {
    required Map<String, int> expectedRevisions,
    Map<String, String>? expectedDigests,
    void Function()? checkCancelled,
  }) => _exclusive(() async {
    final incoming = tombstones.toList();
    if (incoming.isEmpty) return;
    if (incoming.length > 10000 ||
        incoming.map((t) => t.packId).toSet().length != incoming.length) {
      throw const FormatException('Invalid tombstone batch');
    }
    final before = await _readTombstoneLedger();
    final next = Map<String, PackRetirement>.of(before);
    for (final evidence in incoming) {
      checkCancelled?.call();
      // Revalidate even an object constructed by a local caller.
      PackTombstone.fromJson(evidence.toJson());
      final old = before[evidence.packId];
      if (old != null) {
        if (old.tombstone!.sourceOrigin != evidence.sourceOrigin ||
            evidence.revision < old.tombstone!.revision) {
          throw StateError('Conflicting tombstone evidence');
        }
        if (evidence.revision == old.tombstone!.revision) {
          if (jsonEncode(evidence.toJson()) !=
              jsonEncode(old.tombstone!.toJson())) {
            throw StateError('Conflicting tombstone evidence');
          }
          continue;
        }
        next[evidence.packId] = PackRetirement(
          packId: old.packId,
          name: old.name,
          topicId: old.topicId,
          installedRevision: old.installedRevision,
          manifestSha256: old.manifestSha256,
          removedAt: old.removedAt,
          publicSyncEligible: old.publicSyncEligible,
          tombstone: evidence,
        );
        continue;
      }
      final installed = await readInstalled(evidence.packId);
      final removed = installed == null
          ? await _readLocalRemoval(evidence.packId)
          : null;
      final expected = expectedRevisions[evidence.packId];
      final known = installed == null ? removed : _retirement(installed);
      if (known == null ||
          !known.publicSyncEligible ||
          expected == null ||
          known.installedRevision != expected ||
          evidence.revision <= known.installedRevision ||
          expectedDigests?[evidence.packId] != null &&
              expectedDigests![evidence.packId] != known.manifestSha256) {
        throw StateError('Tombstone does not match known local content');
      }
      next[evidence.packId] = PackRetirement(
        packId: known.packId,
        name: known.name,
        topicId: known.topicId,
        installedRevision: known.installedRevision,
        manifestSha256: known.manifestSha256,
        removedAt: known.removedAt,
        publicSyncEligible: known.publicSyncEligible,
        tombstone: evidence,
      );
    }
    checkCancelled?.call();
    final pending = File(p.join(root.path, 'tombstones.pending'));
    final bytes = utf8.encode(
      jsonEncode({
        'schemaVersion': 1,
        'packs': [
          for (final id in next.keys.toList()..sort()) next[id]!.toJson(),
        ],
      }),
    );
    if (bytes.length > 16 * 1024 * 1024) {
      throw const FormatException('Tombstone ledger exceeds limit');
    }
    try {
      await _io.write(pending, bytes);
      if (sha256
              .convert(await _readBounded(pending, limit: 16 * 1024 * 1024))
              .toString() !=
          sha256.convert(bytes).toString()) {
        throw const FormatException('Tombstone ledger integrity check failed');
      }
      checkCancelled?.call();
      await _io.activate(pending, File(p.join(root.path, 'tombstones.json')));
    } finally {
      try {
        if (await pending.exists()) await pending.delete();
      } on FileSystemException {
        /* Recovery retries. */
      }
    }
  });

  Future<PackTombstone?> readTombstone(String packId) async =>
      (await _readTombstoneLedger())[packId]?.tombstone;

  Future<List<PackRetirement>> readRetirements() async {
    final records = await _readTombstoneLedger();
    final retiredDirectories = {
      for (final id in records.keys) p.basename(_packDirectory(id).path),
    };
    if (await root.exists()) {
      await for (final directory in root.list(followLinks: false)) {
        if (directory is! Directory ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(p.basename(directory.path))) {
          continue;
        }
        if (retiredDirectories.contains(p.basename(directory.path))) continue;
        final active = File(p.join(directory.path, 'active'));
        if (!await active.exists()) continue;
        final pointer = utf8.decode(
          await _readBounded(active, limit: 64 * 1024),
        );
        if (!pointer.startsWith('{')) continue;
        final record = PackRetirement.fromJson(
          LocalPackManifest.object(jsonDecode(pointer)),
        );
        if (record.isAuthoritative ||
            p.basename(_packDirectory(record.packId).path) !=
                p.basename(directory.path)) {
          throw const FormatException('Invalid local removal identity');
        }
        records.putIfAbsent(record.packId, () => record);
      }
    }
    return List.unmodifiable(
      (records.values.toList()..sort((a, b) => a.packId.compareTo(b.packId))),
    );
  }

  Future<bool> hasRetirements() async => (await readRetirements()).isNotEmpty;

  Future<PackRetirement?> _readLocalRemoval(String packId) async {
    final active = File(p.join(_packDirectory(packId).path, 'active'));
    if (!await active.exists()) return null;
    final pointer = utf8.decode(await _readBounded(active, limit: 64 * 1024));
    if (!pointer.startsWith('{')) return null;
    final record = PackRetirement.fromJson(
      LocalPackManifest.object(jsonDecode(pointer)),
    );
    if (record.packId != packId || record.isAuthoritative) {
      throw const FormatException('Invalid local removal identity');
    }
    return record;
  }

  Future<Map<String, PackRetirement>> _readTombstoneLedger() async {
    final file = File(p.join(root.path, 'tombstones.json'));
    if (!await file.exists()) return {};
    final envelope = LocalPackManifest.record(
      jsonDecode(
        utf8.decode(await _readBounded(file, limit: 16 * 1024 * 1024)),
      ),
      {'schemaVersion', 'packs'},
    );
    if (envelope['schemaVersion'] != 1 ||
        envelope['schemaVersion'] is! int ||
        envelope['packs'] is! List ||
        (envelope['packs'] as List).length > 10000) {
      throw const FormatException('Invalid tombstone ledger');
    }
    final records = <String, PackRetirement>{};
    for (final raw in envelope['packs'] as List) {
      final record = PackRetirement.fromJson(LocalPackManifest.object(raw));
      if (!record.isAuthoritative || records.containsKey(record.packId)) {
        throw const FormatException('Invalid tombstone ledger record');
      }
      records[record.packId] = record;
    }
    return records;
  }

  PackRetirement _retirement(
    InstalledLocalPack installed, [
    PackTombstone? tombstone,
  ]) => PackRetirement(
    packId: installed.manifest.pack.id,
    name: installed.manifest.pack.name,
    topicId: installed.manifest.pack.topicId,
    installedRevision: installed.manifest.pack.revision,
    manifestSha256: installed.manifest.digest,
    removedAt: DateTime.now().toUtc(),
    publicSyncEligible:
        installed.manifest.toJson()['provenance']['mode'] == 'cleared-test',
    tombstone: tombstone,
  );

  void _expectInstalled(
    InstalledLocalPack installed,
    int revision,
    String? digest,
  ) {
    if (installed.manifest.pack.revision != revision ||
        digest != null && installed.manifest.digest != digest) {
      throw StateError('Installed Pack changed before retirement');
    }
  }

  Future<PackPlaybackLease?> retainForSession(Iterable<String> packIds) =>
      _exclusive(() async {
        final ids = packIds.toList();
        if (ids.isEmpty || ids.toSet().length != ids.length) return null;
        final packs = <InstalledLocalPack>[];
        for (final id in ids) {
          final installed = await readInstalled(id);
          if (installed == null) return null;
          packs.add(installed);
        }
        final paths = <String>[];
        try {
          for (final installed in packs) {
            final path = await installed.directory.resolveSymbolicLinks();
            final existing = PackPlaybackLease._holds[path];
            if (existing != null) {
              existing.references++;
            } else {
              final leaseFile = File(p.join(path, '.playback.lock'));
              final file = await leaseFile.open(
                mode: await leaseFile.exists()
                    ? FileMode.read
                    : FileMode.append,
              );
              try {
                await file.lock(FileLock.shared);
              } catch (_) {
                await file.close();
                rethrow;
              }
              PackPlaybackLease._holds[path] = _PlaybackHold(file);
            }
            paths.add(path);
          }
          return PackPlaybackLease._(this, packs, paths);
        } catch (_) {
          for (final path in paths) {
            final held = PackPlaybackLease._holds[path]!;
            if (--held.references == 0) {
              PackPlaybackLease._holds.remove(path);
              await held.file.close();
            }
          }
          rethrow;
        }
      });

  /// Explicit Home/cold-start cleanup, bounded by generation directories removed.
  /// Shared read leases protect active snapshots in this and other processes.
  Future<int> cleanupRetired({int maxEntries = 8}) => _exclusive(() async {
    if (maxEntries < 1 || maxEntries > 64) {
      throw ArgumentError.value(maxEntries);
    }
    final deleted = await _readTombstoneLedger();
    final deletedDirectories = {
      for (final id in deleted.keys) p.basename(_packDirectory(id).path),
    };
    var removed = 0;
    await for (final directory in root.list(followLinks: false)) {
      if (removed >= maxEntries) break;
      if (directory is! Directory ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(p.basename(directory.path))) {
        continue;
      }
      String? current;
      final active = File(p.join(directory.path, 'active'));
      try {
        if (await active.exists()) {
          final pointer = utf8.decode(
            await _readBounded(active, limit: 64 * 1024),
          );
          if (pointer.startsWith('{')) {
            final record = PackRetirement.fromJson(
              LocalPackManifest.object(jsonDecode(pointer)),
            );
            if (record.isAuthoritative ||
                p.basename(_packDirectory(record.packId).path) !=
                    p.basename(directory.path)) {
              continue;
            }
          } else if (RegExp(r'^generation-[A-Za-z0-9]+$').hasMatch(pointer)) {
            current = pointer;
          } else {
            continue;
          }
        }
      } on FileSystemException {
        continue;
      } on FormatException {
        continue;
      }
      // A durable tombstone retires even the last active generation. Otherwise
      // only non-current generations may be reclaimed after their readers exit.
      if (deletedDirectories.contains(p.basename(directory.path))) {
        current = null;
      }
      await for (final entry in directory.list(followLinks: false)) {
        if (removed >= maxEntries) break;
        if (entry is! Directory ||
            !RegExp(
              r'^generation-[A-Za-z0-9]+$',
            ).hasMatch(p.basename(entry.path))) {
          continue;
        }
        if (p.basename(entry.path) == current) continue;
        final path = await entry.resolveSymbolicLinks();
        if (PackPlaybackLease._holds.containsKey(path)) continue;
        RandomAccessFile? lease;
        try {
          lease = await File(
            p.join(path, '.playback.lock'),
          ).open(mode: FileMode.append);
          await lease.lock(FileLock.exclusive);
          await entry.delete(recursive: true);
          removed++;
        } on FileSystemException {
          /* Live foreign snapshot or cleanup IO error. */
        } finally {
          try {
            await lease?.close();
          } on FileSystemException {
            /* Best effort cleanup. */
          }
        }
      }
    }
    return removed;
  });

  Directory _packDirectory(String packId) => Directory(
    p.join(root.path, sha256.convert(utf8.encode(packId)).toString()),
  );

  Future<Uint8List> _readBounded(File file, {int? limit}) async {
    limit ??= limits.fileBytes;
    if (await file.length() > limit) {
      throw const FormatException('Pack file exceeds size limit');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(0, limit + 1)) {
      bytes.add(chunk);
      if (bytes.length > limit) {
        throw const FormatException('Pack file exceeds size limit');
      }
    }
    return bytes.takeBytes();
  }

  Future<T> _exclusive<T>(Future<T> Function() operation) async {
    await root.create(recursive: true);
    final key = await root.resolveSymbolicLinks();
    final previous = _queues[key] ?? Future<void>.value();
    final done = Completer<void>();
    _queues[key] = done.future;
    await previous;
    RandomAccessFile? lock;
    try {
      lock = await File(
        p.join(key, '.install.lock'),
      ).open(mode: FileMode.append);
      await lock.lock(FileLock.blockingExclusive);
      return await operation();
    } finally {
      try {
        await lock?.close();
      } finally {
        done.complete();
        if (identical(_queues[key], done.future)) _queues.remove(key);
      }
    }
  }
}
