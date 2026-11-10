import 'package:idb_shim/idb_client_native.dart';

import 'dataset_store.dart';
import 'indexed_db_dataset_store.dart';

DatasetStore createStore() {
  try {
    // Use native explicitly: the package's browser convenience factory falls
    // back to memory, which would incorrectly promise durable storage.
    return IndexedDbDatasetStore(idbFactoryNative);
  } catch (_) {
    throw const DatasetStorageFailure('storage-blocked');
  }
}
