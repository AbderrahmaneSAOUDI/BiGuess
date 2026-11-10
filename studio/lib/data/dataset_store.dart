import 'dataset_store_factory_stub.dart'
    if (dart.library.js_interop) 'dataset_store_factory_web.dart'
    as platform;
import 'studio_dataset.dart';

class DatasetStorageFailure implements Exception {
  const DatasetStorageFailure(this.code);
  final String code;
  @override
  String toString() => 'DatasetStorageFailure($code)';
}

abstract interface class DatasetStore {
  Future<DatasetSnapshot?> read(DatasetScope scope);
  Future<DatasetScope?> offlineScope(String project, String uid);
  Future<void> authorize(DatasetScope scope);
  Future<DatasetSnapshot> save(
    DatasetSnapshot snapshot, {
    required int expectedVersion,
  });
  Future<void> revoke(String project, String uid);
  void close();
}

DatasetStore createDatasetStore() => platform.createStore();
