import 'dart:async';
import 'dart:convert';

import 'package:idb_shim/idb.dart';

import 'dataset_store.dart';
import 'studio_dataset.dart';

/// IndexedDB only in production. The injectable factory supports actual browser
/// tests and deterministic in-memory transaction tests without native storage.
class IndexedDbDatasetStore implements DatasetStore {
  IndexedDbDatasetStore(
    this.factory, {
    this.databaseName = 'biguess-studio-datasets',
    this.openTimeout = const Duration(seconds: 10),
    this.beforeSaveCommit,
  });
  final IdbFactory factory;
  final String databaseName;
  final Duration openTimeout;

  /// Fault injection after the put, while its transaction can still be aborted.
  /// Production never supplies this hook.
  final void Function()? beforeSaveCommit;
  static const databaseVersion = 2;
  Database? _database;
  Future<Database>? _opening;
  StreamSubscription<VersionChangeEvent>? _versionChange;
  final _transactions = <Transaction>{};
  bool _closed = false;
  String _closedCode = 'storage-closed';

  Future<Database> _open() {
    if (_closed) throw DatasetStorageFailure(_closedCode);
    if (_database != null) return Future.value(_database);
    return _opening ??= _openDatabase();
  }

  Future<Database> _openDatabase() async {
    var timedOut = false;
    try {
      final pending = factory.open(
        databaseName,
        version: databaseVersion,
        onUpgradeNeeded: (event) {
          final db = event.database;
          // v1 stores snapshots. v2 adds account-specific offline reopening
          // receipts; existing v1 snapshots require fresh online authorization.
          if (event.oldVersion < 1) db.createObjectStore('datasets');
          if (event.oldVersion < 2) db.createObjectStore('accounts');
        },
      );
      // A blocked request can resolve after timeout/sign-out. Never leave its
      // eventual connection open or make it usable by an abandoned account.
      unawaited(
        pending.then<void>((db) {
          if (_closed || timedOut) db.close();
        }, onError: (Object _, StackTrace _) {}),
      );
      final db = await pending.timeout(
        openTimeout,
        onTimeout: () {
          timedOut = true;
          throw const DatasetStorageFailure('storage-blocked');
        },
      );
      if (_closed) {
        db.close();
        throw DatasetStorageFailure(_closedCode);
      }
      _database = db;
      _versionChange = db.onVersionChange.listen((_) {
        _closedCode = 'storage-version';
        close();
      });
      return db;
    } catch (error) {
      _opening = null;
      throw _failure(error);
    }
  }

  Future<T> _transaction<T>(
    List<String> stores,
    String mode,
    Future<T> Function(Transaction) action,
  ) async {
    Transaction? tx;
    Future<Database>? completed;
    try {
      final db = await _open();
      if (_closed) throw DatasetStorageFailure(_closedCode);
      tx = db.transactionList(stores, mode);
      _transactions.add(tx);
      completed = tx.completed;
      // Observe early browser aborts immediately, then await the same future
      // below so quota/security failures are reported with no partial result.
      unawaited(
        completed.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
      final result = await action(tx);
      if (_closed) throw DatasetStorageFailure(_closedCode);
      await completed;
      return result;
    } catch (error) {
      try {
        tx?.abort();
      } catch (_) {
        /* Already completed/aborted. */
      }
      if (completed != null) {
        try {
          await completed;
        } catch (_) {
          /* Preserve original failure. */
        }
      }
      throw _failure(error);
    } finally {
      if (tx != null) _transactions.remove(tx);
    }
  }

  @override
  Future<DatasetSnapshot?> read(DatasetScope scope) =>
      _transaction(['accounts', 'datasets'], idbModeReadOnly, (tx) async {
        final receiptRow = await tx
            .objectStore('accounts')
            .getObject(scope.accountKey);
        if (receiptRow == null) return null;
        final receipt = _object(receiptRow);
        if (receipt['allowed'] != true ||
            DatasetScope.fromJson(_object(receipt['scope'])).namespace !=
                scope.namespace) {
          throw const DatasetStorageFailure('storage-revoked');
        }
        final row = await tx.objectStore('datasets').getObject(scope.namespace);
        return _snapshot(row, scope);
      });

  @override
  Future<DatasetScope?> offlineScope(String project, String uid) =>
      _transaction(['accounts', 'datasets'], idbModeReadOnly, (tx) async {
        final row = await tx
            .objectStore('accounts')
            .getObject(jsonEncode([project, uid]));
        if (row == null) return null;
        final receipt = _object(row);
        if (receipt['allowed'] != true) return null;
        final scope = DatasetScope.fromJson(_object(receipt['scope']));
        if (scope.project != project || scope.uid != uid) {
          throw const FormatException('Wrong offline receipt');
        }
        final snapshot = _snapshot(
          await tx.objectStore('datasets').getObject(scope.namespace),
          scope,
        );
        return snapshot?.lastSyncedAt == null || snapshot?.resumeCursor == null
            ? null
            : scope;
      });

  @override
  Future<void> authorize(DatasetScope scope) => _transaction(
    ['accounts'],
    idbModeReadWrite,
    (tx) async {
      // Replaces the current role pointer atomically; old role snapshots/queues
      // remain durable but cannot be reopened through the offline policy.
      await tx.objectStore('accounts').put({
        'scope': scope.toJson(),
        'allowed': true,
      }, scope.accountKey);
    },
  );

  @override
  Future<DatasetSnapshot> save(
    DatasetSnapshot snapshot, {
    required int expectedVersion,
  }) => _transaction(['accounts', 'datasets'], idbModeReadWrite, (tx) async {
    final scope = snapshot.scope;
    final receiptRow = await tx
        .objectStore('accounts')
        .getObject(scope.accountKey);
    if (receiptRow == null) {
      throw const DatasetStorageFailure('storage-revoked');
    }
    final receipt = _object(receiptRow);
    if (receipt['allowed'] != true ||
        DatasetScope.fromJson(_object(receipt['scope'])).namespace !=
            scope.namespace) {
      throw const DatasetStorageFailure('storage-revoked');
    }
    final store = tx.objectStore('datasets');
    final current = _snapshot(await store.getObject(scope.namespace), scope);
    if ((current?.version ?? 0) != expectedVersion ||
        snapshot.version != expectedVersion ||
        expectedVersion < 0 ||
        expectedVersion >= 9007199254740991) {
      throw const DatasetStorageFailure('storage-conflict');
    }
    final next = snapshot.copyWith(version: expectedVersion + 1);
    // JSON strings make the model/schema boundary explicit and avoid storing
    // platform-specific values or accidentally serializing a token object.
    await store.put(jsonEncode(next.toJson()), scope.namespace);
    beforeSaveCommit?.call();
    // Save never changes a receipt: late writes cannot undo logout/revocation.
    return next;
  });

  @override
  Future<void> revoke(String project, String uid) =>
      _transaction(['accounts'], idbModeReadWrite, (tx) async {
        final store = tx.objectStore('accounts');
        final key = jsonEncode([project, uid]);
        // Deleting a tiny receipt frees quota instead of requiring a write of
        // a replacement row. Snapshots and queued drafts remain untouched.
        await store.delete(key);
      });

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final tx in _transactions.toList()) {
      try {
        tx.abort();
      } catch (_) {
        /* Already completed/aborted. */
      }
    }
    unawaited(_versionChange?.cancel());
    _database?.close();
    _database = null;
  }
}

DatasetSnapshot? _snapshot(Object? row, DatasetScope expected) {
  if (row == null) return null;
  if (row is! String) {
    throw const FormatException('Invalid snapshot representation');
  }
  final snapshot = DatasetSnapshot.fromJson(_object(jsonDecode(row)));
  if (snapshot.scope.namespace != expected.namespace) {
    throw const FormatException('Wrong snapshot namespace');
  }
  return snapshot;
}

Map<String, Object?> _object(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw const FormatException('Invalid storage record');
  }
  return Map<String, Object?>.from(value);
}

DatasetStorageFailure _failure(Object error) {
  if (error is DatasetStorageFailure) return error;
  if (error is FormatException || error is TypeError) {
    return const DatasetStorageFailure('storage-corrupt');
  }
  final text = error.toString().toLowerCase();
  if (text.contains('quota')) {
    return const DatasetStorageFailure('quota-exceeded');
  }
  if (text.contains('version') || text.contains('downgrade')) {
    return const DatasetStorageFailure('storage-version');
  }
  return const DatasetStorageFailure('storage-blocked');
}
