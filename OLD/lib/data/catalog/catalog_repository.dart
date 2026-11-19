import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'catalog_cache_store.dart';
import 'catalog_models.dart';

class CatalogFailure implements Exception {
  const CatalogFailure(this.code);
  final String code;
  @override
  String toString() => 'CatalogFailure($code)';
}

abstract interface class CatalogRepository {
  Future<CatalogSnapshot?> readCached();
  Future<CatalogSnapshot> refreshTopics();
  Future<CatalogSnapshot> refreshPacks(String topicId);
  void close();
}

/// Summary-only anonymous v1 discovery. All network reads are explicit methods;
/// neither construction, cache restoration nor local gameplay triggers HTTP.
class HttpCatalogRepository implements CatalogRepository {
  HttpCatalogRepository({
    required Uri base,
    required this.store,
    HttpClient? httpClient,
    DateTime Function()? now,
  }) : base = _base(base),
       _client = httpClient,
       _now = now ?? DateTime.now;
  final Uri base;
  final CatalogCacheStore store;
  HttpClient? _client;
  HttpClient get _http =>
      _client ??= (HttpClient()
        ..connectionTimeout = const Duration(seconds: 15));
  final DateTime Function() _now;
  String get origin => base.origin;
  CatalogSnapshot? _snapshot;
  Future<CatalogSnapshot?>? _loading;
  bool _loaded = false, _busy = false, _closed = false;
  @override
  Future<CatalogSnapshot?> readCached() {
    if (_closed) return Future.error(const CatalogFailure('closed'));
    if (_loaded) return Future.value(_snapshot);
    return _loading ??= _readCache();
  }

  Future<CatalogSnapshot?> _readCache() async {
    try {
      final cached = await store.read(origin);
      if (_closed) throw const CatalogFailure('closed');
      _snapshot = cached;
      return cached;
    } catch (error) {
      if (error is CatalogFailure) rethrow;
      throw const CatalogFailure('cache-unavailable');
    } finally {
      _loaded = true;
    }
  }

  Future<CatalogSnapshot> _run(
    Future<CatalogSnapshot> Function(CatalogSnapshot) action,
  ) async {
    if (_closed) throw const CatalogFailure('closed');
    if (_busy) throw const CatalogFailure('busy');
    _busy = true;
    try {
      // A corrupt/unavailable summary cache never prevents a deliberate online
      // recovery; the installed content store is entirely independent.
      try {
        await readCached();
      } on CatalogFailure catch (error) {
        if (error.code == 'closed') rethrow;
      }
      final before = _snapshot ?? CatalogSnapshot.empty(origin);
      final staged = await action(before);
      if (_closed) throw const CatalogFailure('closed');
      try {
        await store.write(staged);
      } catch (_) {
        throw const CatalogFailure('cache-write-failed');
      }
      if (_closed) throw const CatalogFailure('closed');
      _snapshot = staged;
      return staged;
    } finally {
      _busy = false;
    }
  }

  @override
  Future<CatalogSnapshot> refreshTopics() => _run((before) async {
    final result = await _scan(false, null, before.topicsEtag);
    final topics = result.unchanged
        ? before.topics
        : _mergeTopics(
            before.topics,
            result.items.map(CatalogTopicSummary.fromPublic).toList(),
          );
    final unavailable = topics
        .where((t) => !t.available)
        .map((t) => t.id)
        .toSet();
    return CatalogSnapshot(
      origin: origin,
      topics: topics,
      packs: before.packs
          .map(
            (p) =>
                unavailable.contains(p.topicId) ? p.withAvailability(false) : p,
          )
          .toList(),
      topicsCheckedAt: _now().toUtc(),
      packsCheckedAt: before.packsCheckedAt,
      topicsEtag: result.etag,
      packsEtags: {
        for (final e in before.packsEtags.entries)
          if (!unavailable.contains(e.key)) e.key: e.value,
      },
    );
  });
  @override
  Future<CatalogSnapshot> refreshPacks(String topicId) => _run((before) async {
    catalogId(topicId);
    if (!before.topics.any((t) => t.id == topicId)) {
      throw const CatalogFailure('topic-unknown');
    }
    final result = await _scan(true, topicId, before.packsEtags[topicId]);
    final incoming = result.items.map(CatalogPackSummary.fromPublic).toList();
    if (incoming.any((p) => p.topicId != topicId)) {
      throw const CatalogFailure('invalid-catalog');
    }
    if (incoming.any(
      (candidate) => before.packs.any(
        (old) => old.id == candidate.id && old.topicId != candidate.topicId,
      ),
    )) {
      throw const CatalogFailure('invalid-catalog');
    }
    final packs = result.unchanged
        ? before.packs
        : <CatalogPackSummary>[
            ...before.packs.where((p) => p.topicId != topicId),
            ..._mergePacks(before.packsForTopic(topicId), incoming),
          ];
    final etags = Map<String, String>.of(before.packsEtags)..remove(topicId);
    if (result.etag != null) etags[topicId] = result.etag!;
    return CatalogSnapshot(
      origin: origin,
      topics: before.topics
          .map(
            (t) =>
                t.id == topicId ? t.withAvailability(!result.unavailable) : t,
          )
          .toList(),
      packs: packs,
      topicsCheckedAt: before.topicsCheckedAt,
      packsCheckedAt: {...before.packsCheckedAt, topicId: _now().toUtc()},
      topicsEtag: result.unavailable ? null : before.topicsEtag,
      packsEtags: etags,
    );
  });

  Future<_Scan> _scan(bool packs, String? topicId, String? validator) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _pages(packs, topicId, validator);
      } on CatalogFailure catch (error) {
        if (error.code != 'cursor-expired' || attempt != 0) rethrow;
      }
    }
    throw const CatalogFailure('cursor-expired');
  }

  Future<_Scan> _pages(bool packs, String? topicId, String? validator) async {
    final items = <Map<String, dynamic>>[],
        ids = <String>{},
        cursors = <String>{};
    String? cursor, snapshot, etag;
    for (var page = 0; page < 100; page++) {
      if (_closed) throw const CatalogFailure('closed');
      final uri = base
          .resolve(
            packs ? '/content/v1/catalog/packs' : '/content/v1/catalog/topics',
          )
          .replace(
            queryParameters: {
              'limit': '100',
              if (packs) 'topicId': topicId!,
              'cursor': ?cursor,
            },
          );
      final _Reply reply;
      try {
        reply = await _get(uri, page == 0 ? validator : null);
      } on CatalogFailure {
        rethrow;
      } catch (_) {
        throw const CatalogFailure('catalog-unavailable');
      }
      if (reply.status == 304) {
        if (page != 0 ||
            validator == null ||
            reply.etag != validator ||
            reply.body.isNotEmpty) {
          throw const CatalogFailure('invalid-catalog');
        }
        return _Scan(const [], validator, unchanged: true);
      }
      if (reply.status == 409) throw const CatalogFailure('cursor-expired');
      if (packs && {403, 404, 410}.contains(reply.status)) {
        try {
          final error = catalogObject(jsonDecode(reply.body));
          catalogKeys(error, {'protocolVersion', 'error'});
          final detail = catalogObject(error['error']);
          catalogKeys(detail, {
            'code',
            'message',
            'requestId',
            'retryable',
            'currentRevision',
          });
          final code = {
            403: 'unavailable',
            404: 'not_found',
            410: 'deleted',
          }[reply.status];
          if (error['protocolVersion'] != 1 || detail['code'] != code) {
            throw const FormatException();
          }
          return const _Scan([], null, unavailable: true);
        } catch (_) {
          throw const CatalogFailure('invalid-catalog');
        }
      }
      if (reply.status != 200) {
        throw const CatalogFailure('catalog-unavailable');
      }
      try {
        final body = catalogObject(jsonDecode(reply.body));
        catalogKeys(body, {
          'protocolVersion',
          'snapshot',
          'items',
          'nextCursor',
        });
        if (body['protocolVersion'] != 1 ||
            body['snapshot'] is! String ||
            (body['snapshot'] as String).isEmpty ||
            body['items'] is! List ||
            (body['items'] as List).length > 100 ||
            !(body['nextCursor'] == null ||
                body['nextCursor'] is String &&
                    (body['nextCursor'] as String).isNotEmpty)) {
          throw const FormatException();
        }
        if (snapshot != null && snapshot != body['snapshot']) {
          throw const FormatException();
        }
        snapshot = body['snapshot'] as String;
        for (final raw in body['items'] as List) {
          final row = catalogObject(raw);
          if (packs) {
            CatalogPackSummary.fromPublic(row);
          } else {
            CatalogTopicSummary.fromPublic(row);
          }
          if (!ids.add(row['id'] as String)) throw const FormatException();
          items.add(row);
        }
        final next = body['nextCursor'] as String?;
        if (page == 0 && next == null) etag = reply.etag;
        if (next == null) return _Scan(items, etag);
        if (next.length > 8192 || !cursors.add(next)) {
          throw const FormatException();
        }
        cursor = next;
      } catch (_) {
        throw const CatalogFailure('invalid-catalog');
      }
    }
    throw const CatalogFailure('catalog-too-large');
  }

  Future<_Reply> _get(Uri uri, String? validator) async {
    final request = await _http
        .getUrl(uri)
        .timeout(const Duration(seconds: 15));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (validator != null) {
      request.headers.set(HttpHeaders.ifNoneMatchHeader, validator);
    }
    final response = await request.close().timeout(const Duration(seconds: 20));
    final data = <int>[];
    await (() async {
      await for (final bytes in response) {
        if (data.length + bytes.length > 512 * 1024) {
          request.abort();
          throw const CatalogFailure('catalog-too-large');
        }
        data.addAll(bytes);
      }
    })().timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        request.abort();
        throw const CatalogFailure('catalog-unavailable');
      },
    );
    if (_closed) throw const CatalogFailure('closed');
    final tag = response.headers.value(HttpHeaders.etagHeader);
    String? checked;
    if (tag != null) {
      try {
        checked = catalogEtag(tag);
      } catch (_) {
        throw const CatalogFailure('invalid-catalog');
      }
    }
    if (response.statusCode == 200 &&
        response.headers.contentType?.mimeType != 'application/json') {
      throw const CatalogFailure('invalid-catalog');
    }
    return _Reply(response.statusCode, utf8.decode(data), checked);
  }

  @override
  void close() {
    _closed = true;
    _client?.close(force: true);
  }
}

Uri _base(Uri value) {
  final local = {'localhost', '127.0.0.1', '::1'}.contains(value.host);
  if (!(value.scheme == 'https' || value.scheme == 'http' && local) ||
      value.host.isEmpty ||
      value.userInfo.isNotEmpty ||
      value.hasQuery ||
      value.hasFragment ||
      !{'', '/'}.contains(value.path)) {
    throw ArgumentError.value(value, 'base', 'Expected a public HTTPS origin');
  }
  return Uri.parse(value.origin);
}

List<CatalogTopicSummary> _mergeTopics(
  List<CatalogTopicSummary> before,
  List<CatalogTopicSummary> incoming,
) {
  final ids = incoming.map((t) => t.id).toSet();
  return [
    ...incoming,
    ...before
        .where((t) => !ids.contains(t.id))
        .map((t) => t.withAvailability(false)),
  ];
}

List<CatalogPackSummary> _mergePacks(
  List<CatalogPackSummary> before,
  List<CatalogPackSummary> incoming,
) {
  final ids = incoming.map((p) => p.id).toSet();
  return [
    ...incoming,
    ...before
        .where((p) => !ids.contains(p.id))
        .map((p) => p.withAvailability(false)),
  ];
}

class _Reply {
  const _Reply(this.status, this.body, this.etag);
  final int status;
  final String body;
  final String? etag;
}

class _Scan {
  const _Scan(
    this.items,
    this.etag, {
    this.unchanged = false,
    this.unavailable = false,
  });
  final List<Map<String, dynamic>> items;
  final String? etag;
  final bool unchanged, unavailable;
}
