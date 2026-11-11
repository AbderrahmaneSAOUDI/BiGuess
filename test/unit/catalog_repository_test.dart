import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:biguess/data/catalog/catalog_cache_store.dart';
import 'package:biguess/data/catalog/catalog_models.dart';
import 'package:biguess/data/catalog/catalog_repository.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> topic(String id) => {
  'id': id,
  'name': 'Topic $id',
  'revision': 1,
};
Map<String, Object?> pack(String id, {String parent = 'a'}) => {
  'id': id,
  'topicId': parent,
  'name': 'Pack $id',
  'revision': 1,
  'cardCount': 4,
  'manifestSha256': 'a' * 64,
};
Map<String, Object?> page(
  List<Map<String, Object?>> items, {
  String? next,
  String snapshot = 'snapshot',
}) => {
  'protocolVersion': 1,
  'snapshot': snapshot,
  'items': items,
  'nextCursor': next,
};
final etag = '"${'a' * 64}"';
Matcher failure(String code) =>
    isA<CatalogFailure>().having((e) => e.code, 'code', code);

class FailingStore extends MemoryCatalogCacheStore {
  bool fail = false;
  @override
  Future<void> write(CatalogSnapshot snapshot) async {
    if (fail) throw const FileSystemException('synthetic quota');
    await super.write(snapshot);
  }
}

void main() {
  late HttpServer server;
  late HttpCatalogRepository repository;
  late MemoryCatalogCacheStore store;
  late List<Uri> requests;
  late Future<void> Function(HttpRequest) handler;
  Future<void> reply(
    HttpRequest request,
    Object? body, {
    int status = 200,
    String? tag,
  }) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    if (tag != null) request.response.headers.set(HttpHeaders.etagHeader, tag);
    if (body != null) request.response.write(jsonEncode(body));
    await request.response.close();
  }

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    requests = [];
    store = MemoryCatalogCacheStore();
    handler = (request) => reply(request, page([topic('a')]));
    server.listen((request) async {
      requests.add(request.uri);
      expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
      expect(request.headers.value(HttpHeaders.cookieHeader), isNull);
      expect(
        request.headers.value(HttpHeaders.proxyAuthorizationHeader),
        isNull,
      );
      await handler(request);
    });
    repository = HttpCatalogRepository(
      base: Uri.parse('http://127.0.0.1:${server.port}'),
      store: store,
    );
  });
  tearDown(() async {
    repository.close();
    await server.close(force: true);
  });

  test(
    'construction and cache restore perform no requests or HTTP client allocation',
    () async {
      final calls = <Uri>[];
      await HttpOverrides.runZoned(
        () async {
          final repo = HttpCatalogRepository(
            base: Uri.parse('https://public.example'),
            store: MemoryCatalogCacheStore(),
          );
          expect(await repo.readCached(), isNull);
          repo.close();
        },
        createHttpClient: (_) {
          calls.add(Uri());
          throw StateError('HTTP allocation forbidden');
        },
      );
      expect(calls, isEmpty);
      expect(requests, isEmpty);
    },
  );
  test(
    'anonymous fixed public endpoints stage full pages and keep summaries only',
    () async {
      handler = (request) async {
        expect(request.uri.path, '/content/v1/catalog/topics');
        expect(request.uri.queryParameters['limit'], '100');
        await reply(
          request,
          request.uri.queryParameters['cursor'] == null
              ? page([topic('a')], next: 'opaque+/2')
              : page([topic('b')]),
        );
      };
      final result = await repository.refreshTopics();
      expect(result.topics.map((t) => t.id), ['a', 'b']);
      expect(result.topicsEtag, isNull);
      expect(requests.last.queryParameters['cursor'], 'opaque+/2');
      expect(result.toJson().toString(), isNot(contains('createdByUid')));
    },
  );
  test(
    'single-page complete cache uses conditional304 and retains its entire scope',
    () async {
      var count = 0;
      handler = (request) async {
        count++;
        if (count == 1) {
          expect(request.headers.value('If-None-Match'), isNull);
          await reply(request, page([topic('a')]), tag: etag);
        } else {
          expect(request.headers.value('If-None-Match'), etag);
          await reply(request, null, status: 304, tag: etag);
        }
      };
      final first = await repository.refreshTopics();
      final next = await repository.refreshTopics();
      expect(next.topics.single.id, first.topics.single.id);
      expect(next.topicsEtag, etag);
    },
  );
  test(
    'multi-page cache never treats a first-page validator as complete-data validation',
    () async {
      var scan = 0;
      handler = (request) async {
        expect(request.headers.value('If-None-Match'), isNull);
        if (request.uri.queryParameters['cursor'] == null) {
          scan++;
          await reply(request, page([topic('a')], next: 'next'), tag: etag);
        } else {
          await reply(
            request,
            page([topic(scan == 1 ? 'b' : 'changed')]),
            tag: etag,
          );
        }
      };
      await repository.refreshTopics();
      final next = await repository.refreshTopics();
      expect(next.topics.any((t) => t.id == 'changed' && t.available), true);
      expect(next.topics.singleWhere((t) => t.id == 'b').available, false);
    },
  );
  test(
    'partial failure preserves previous complete memory and durable snapshots',
    () async {
      await repository.refreshTopics();
      final original = await repository.readCached();
      handler = (request) => request.uri.queryParameters['cursor'] == null
          ? reply(request, page([topic('new')], next: 'next'))
          : reply(request, {}, status: 503);
      await expectLater(
        repository.refreshTopics(),
        throwsA(failure('catalog-unavailable')),
      );
      expect(await repository.readCached(), same(original));
      expect(store.value!.topics.single.id, 'a');
    },
  );
  test(
    'expired paging restarts once and discards staged first-attempt data',
    () async {
      var calls = 0;
      handler = (request) async {
        calls++;
        if (calls == 1) {
          await reply(request, page([topic('discard')], next: 'old'));
        } else if (calls == 2) {
          await reply(request, {}, status: 409);
        } else {
          expect(request.uri.queryParameters['cursor'], isNull);
          await reply(request, page([topic('good')]));
        }
      };
      expect((await repository.refreshTopics()).topics.single.id, 'good');
      expect(requests, hasLength(3));
      handler = (request) => reply(request, {}, status: 409);
      await expectLater(
        repository.refreshTopics(),
        throwsA(failure('cursor-expired')),
      );
      expect(requests, hasLength(5));
    },
  );
  for (final invalid in [
    page([
      {...topic('a'), 'createdByUid': 'private'},
    ]),
    page([
      {...topic('a'), 'cards': []},
    ]),
    page([topic('a'), topic('a')]),
    {
      ...page([topic('a')]),
      'protocolVersion': 2,
    },
  ]) {
    test(
      'strict public boundary rejects malformed/private summary ${invalid.keys}',
      () async {
        handler = (request) => reply(request, invalid);
        await expectLater(
          repository.refreshTopics(),
          throwsA(failure('invalid-catalog')),
        );
        expect(await repository.readCached(), isNull);
        expect(store.value, isNull);
      },
    );
  }
  test(
    'complete successful removal marks summaries unavailable; network failure never does',
    () async {
      await repository.refreshTopics();
      handler = (request) => reply(request, page([pack('one')]));
      await repository.refreshPacks('a');
      handler = (request) => reply(request, {}, status: 503);
      await expectLater(
        repository.refreshPacks('a'),
        throwsA(failure('catalog-unavailable')),
      );
      expect((await repository.readCached())!.packs.single.available, true);
      handler = (request) => reply(request, page([]));
      expect(
        (await repository.refreshPacks('a')).packs.single.available,
        false,
      );
    },
  );
  test(
    'unknown/private Pack fields and parent moves cannot enter cache',
    () async {
      handler = (request) => reply(request, page([topic('a'), topic('b')]));
      await repository.refreshTopics();
      handler = (request) => reply(request, page([pack('one')]));
      await repository.refreshPacks('a');
      handler = (request) => reply(request, page([pack('one', parent: 'b')]));
      await expectLater(
        repository.refreshPacks('b'),
        throwsA(failure('invalid-catalog')),
      );
      expect((await repository.readCached())!.packs.single.topicId, 'a');
      handler = (request) => reply(
        request,
        page([
          {...pack('new'), 'owner': 'secret'},
        ]),
      );
      await expectLater(
        repository.refreshPacks('a'),
        throwsA(failure('invalid-catalog')),
      );
    },
  );
  test('write failure does not promote a new memory/durable dataset', () async {
    final failing = FailingStore();
    repository.close();
    repository = HttpCatalogRepository(
      base: Uri.parse('http://127.0.0.1:${server.port}'),
      store: failing,
    );
    await repository.refreshTopics();
    final before = await repository.readCached();
    failing.fail = true;
    handler = (request) => reply(request, page([topic('new')]));
    await expectLater(
      repository.refreshTopics(),
      throwsA(failure('cache-write-failed')),
    );
    expect(await repository.readCached(), same(before));
    expect(failing.value!.topics.single.id, 'a');
  });
  test('redirect responses are never followed to private routes', () async {
    handler = (request) async {
      request.response.statusCode = 302;
      request.response.headers.set('Location', '/studio/v1/sync/initial');
      await request.response.close();
    };
    await expectLater(
      repository.refreshTopics(),
      throwsA(failure('catalog-unavailable')),
    );
    expect(requests, hasLength(1));
  });
  test(
    'file cache survives repository restart offline and namespaces endpoints',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'biguess-public-cache-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/catalog.json');
      repository.close();
      repository = HttpCatalogRepository(
        base: Uri.parse('http://127.0.0.1:${server.port}'),
        store: FileCatalogCacheStore.at(file),
      );
      await repository.refreshTopics();
      repository.close();
      repository = HttpCatalogRepository(
        base: Uri.parse('http://127.0.0.1:${server.port}'),
        store: FileCatalogCacheStore.at(file),
      );
      final before = requests.length;
      expect((await repository.readCached())!.topics.single.id, 'a');
      expect(requests.length, before);
      final other = HttpCatalogRepository(
        base: Uri.parse('https://other.example'),
        store: FileCatalogCacheStore.at(file),
      );
      addTearDown(other.close);
      await expectLater(
        other.readCached(),
        throwsA(failure('cache-unavailable')),
      );
      final cached =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      (cached['topics'] as List).first['actorId'] = 'private';
      await file.writeAsString(jsonEncode(cached));
      final bad = FileCatalogCacheStore.at(file);
      await expectLater(bad.read(repository.origin), throwsFormatException);
    },
  );
  test(
    'overlapping refresh is rejected; close discards late responses',
    () async {
      final gate = Completer<void>();
      handler = (request) async {
        await gate.future;
        await reply(request, page([topic('a')]));
      };
      final operation = repository.refreshTopics();
      while (requests.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      await expectLater(repository.refreshTopics(), throwsA(failure('busy')));
      repository.close();
      gate.complete();
      await expectLater(operation, throwsA(isA<CatalogFailure>()));
      expect(store.value, isNull);
    },
  );
  test(
    'authoritative parent unavailability marks old summaries but does not cache private errors',
    () async {
      handler = (request) => reply(request, page([topic('a')]), tag: etag);
      await repository.refreshTopics();
      handler = (request) => reply(request, page([pack('one')]), tag: etag);
      await repository.refreshPacks('a');
      handler = (request) => reply(request, {
        'protocolVersion': 1,
        'error': {
          'code': 'unavailable',
          'message': 'Topic unavailable',
          'requestId': 'fixture',
          'retryable': false,
          'currentRevision': null,
        },
      }, status: 403);
      final unavailable = await repository.refreshPacks('a');
      expect(unavailable.topics.single.available, false);
      expect(unavailable.packs.single.available, false);
      expect(unavailable.topicsEtag, isNull);
      handler = (request) async {
        expect(request.headers.value('If-None-Match'), isNull);
        await reply(request, page([topic('a')]), tag: etag);
      };
      await repository.refreshTopics();
    },
  );
  test(
    'topic disappearance invalidates Pack validators before a later republished scope refresh',
    () async {
      await repository.refreshTopics();
      handler = (request) => reply(request, page([pack('one')]), tag: etag);
      await repository.refreshPacks('a');
      handler = (request) => reply(request, page([]));
      await repository.refreshTopics();
      expect((await repository.readCached())!.packsEtags, isEmpty);
      handler = (request) async {
        expect(request.headers.value('If-None-Match'), isNull);
        await reply(request, page([pack('one')]), tag: etag);
      };
      expect((await repository.refreshPacks('a')).packs.single.available, true);
    },
  );
  test(
    'repeating cursor or changing snapshot cannot promote a partial scan',
    () async {
      handler = (request) => reply(
        request,
        page([topic(requests.length.toString())], next: 'repeat'),
      );
      await expectLater(
        repository.refreshTopics(),
        throwsA(failure('invalid-catalog')),
      );
      expect(store.value, isNull);
      handler = (request) => reply(
        request,
        request.uri.queryParameters['cursor'] == null
            ? page([topic('a')], next: 'next')
            : page([topic('b')], snapshot: 'different'),
      );
      await expectLater(
        repository.refreshTopics(),
        throwsA(failure('invalid-catalog')),
      );
      expect(store.value, isNull);
    },
  );
  test('oversized HTTP response is aborted without cache promotion', () async {
    handler = (request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write('x' * (512 * 1024 + 1));
      await request.response.close();
    };
    await expectLater(
      repository.refreshTopics(),
      throwsA(failure('catalog-too-large')),
    );
    expect(store.value, isNull);
  });
  test(
    'unconfigured/insecure/credential-bearing/private-path base URLs are rejected',
    () {
      for (final address in [
        'http://remote.example',
        'https://user:secret@public.example',
        'https://public.example/studio',
        'https://public.example/?token=secret',
        'https://public.example/#private',
      ]) {
        expect(
          () => HttpCatalogRepository(base: Uri.parse(address), store: store),
          throwsArgumentError,
        );
      }
    },
  );
}
