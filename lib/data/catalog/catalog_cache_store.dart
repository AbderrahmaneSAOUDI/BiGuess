import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'catalog_models.dart';

abstract interface class CatalogCacheStore {
  Future<CatalogSnapshot?> read(String origin);
  Future<void> write(CatalogSnapshot snapshot);
}

/// Separate app-private summary cache. No installed generation/database writes.
class FileCatalogCacheStore implements CatalogCacheStore {
  FileCatalogCacheStore(Future<File> Function() file) : _file = file;
  FileCatalogCacheStore.at(File file) : _file = (() => Future.value(file));
  final Future<File> Function() _file;
  static const maxBytes = 16 * 1024 * 1024;
  @override
  Future<CatalogSnapshot?> read(String origin) async {
    final file = await _file();
    if (!await file.exists()) return null;
    if (await file.length() > maxBytes) {
      throw const FormatException('Catalog cache exceeds limit');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > maxBytes) {
      throw const FormatException('Catalog cache exceeds limit');
    }
    return CatalogSnapshot.fromJson(
      catalogObject(jsonDecode(utf8.decode(bytes))),
      origin,
    );
  }

  @override
  Future<void> write(CatalogSnapshot snapshot) async {
    final bytes = utf8.encode(jsonEncode(snapshot.toJson()));
    if (bytes.length > maxBytes) {
      throw const FormatException('Catalog cache exceeds limit');
    }
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File(
      '${file.path}.${Random.secure().nextInt(0x7fffffff)}.tmp',
    );
    try {
      await temporary.create(exclusive: true);
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}

class MemoryCatalogCacheStore implements CatalogCacheStore {
  CatalogSnapshot? value;
  @override
  Future<CatalogSnapshot?> read(String origin) async =>
      value == null ? null : CatalogSnapshot.fromJson(value!.toJson(), origin);
  @override
  Future<void> write(CatalogSnapshot snapshot) async {
    value = CatalogSnapshot.fromJson(snapshot.toJson(), snapshot.origin);
  }
}
