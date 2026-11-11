import 'dart:convert';

import 'package:http/http.dart' as http;

import 'dataset_api.dart';

/// Live server review only; publication authority is never cached in IndexedDB.
class PublicationReview {
  const PublicationReview({
    required this.resourceType,
    required this.id,
    required this.revision,
    required this.fingerprint,
    required this.state,
    required this.published,
    required this.publishedRevision,
    required this.eligibleCardCount,
    required this.cards,
    required this.errors,
    required this.rightsApproved,
    required this.initialApproved,
    this.pendingRequestId,
    this.status,
  });
  final String resourceType;
  final String id;
  final int revision;
  final String fingerprint;
  final String state;
  final bool published;
  final int? publishedRevision;
  final int eligibleCardCount;
  final List<Map<String, Object?>> cards;
  final List<String> errors;
  final bool rightsApproved;
  final bool initialApproved;
  final String? pendingRequestId;
  final String? status;

  factory PublicationReview.fromJson(Map<String, dynamic> json) {
    if (json['protocolVersion'] != 1 ||
        !{'topic', 'pack'}.contains(json['resourceType']) ||
        json['id'] is! String ||
        (json['id'] as String).isEmpty ||
        json['revision'] is! int ||
        (json['revision'] as int) < 1 ||
        json['fingerprint'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(json['fingerprint'] as String) ||
        !{'active', 'hidden', 'deleted', 'purged'}.contains(json['state']) ||
        json['published'] is! bool ||
        !(json['publishedRevision'] == null ||
            json['publishedRevision'] is int &&
                (json['publishedRevision'] as int) > 0) ||
        json['eligibleCardCount'] is! int ||
        (json['eligibleCardCount'] as int) < 0 ||
        json['cards'] is! List ||
        json['errors'] is! List ||
        !(json['errors'] as List).every((e) => e is String) ||
        json['rightsApproved'] is! bool ||
        json['initialApproved'] is! bool ||
        !(json['pendingRequestId'] == null ||
            json['pendingRequestId'] is String) ||
        !(json['status'] == null || json['status'] is String)) {
      throw const FormatException('Invalid publication review');
    }
    final cards = <Map<String, Object?>>[];
    for (final value in json['cards'] as List) {
      final card = Map<String, Object?>.from(value as Map);
      if (card['id'] is! String ||
          card['name'] is! String ||
          ![1, 2, 3].contains(card['difficulty']) ||
          card['imageReference'] is! String) {
        throw const FormatException('Invalid publication Card');
      }
      cards.add(Map.unmodifiable(card));
    }
    return PublicationReview(
      resourceType: json['resourceType'] as String,
      id: json['id'] as String,
      revision: json['revision'] as int,
      fingerprint: json['fingerprint'] as String,
      state: json['state'] as String,
      published: json['published'] as bool,
      publishedRevision: json['publishedRevision'] as int?,
      eligibleCardCount: json['eligibleCardCount'] as int,
      cards: List.unmodifiable(cards),
      errors: List<String>.unmodifiable(json['errors'] as List),
      rightsApproved: json['rightsApproved'] as bool,
      initialApproved: json['initialApproved'] as bool,
      pendingRequestId: json['pendingRequestId'] as String?,
      status: json['status'] as String?,
    );
  }
}

abstract interface class PublicationApi {
  Future<PublicationReview> review(
    String token,
    String resourceType,
    String id,
    bool Function() current, {
    String? action,
    PublicationReview? expected,
    String? evidence,
  });
  void close();
}

class WorkerPublicationApi implements PublicationApi {
  WorkerPublicationApi(this.base, this.client);
  final Uri base;
  final http.Client client;
  @override
  Future<PublicationReview> review(
    String token,
    String resourceType,
    String id,
    bool Function() current, {
    String? action,
    PublicationReview? expected,
    String? evidence,
  }) async {
    if (!{'topic', 'pack'}.contains(resourceType) ||
        action != null &&
            (!{
                  'validate',
                  'approve-rights',
                  'approve',
                  'publish',
                  'unpublish',
                }.contains(action) ||
                expected == null ||
                expected.id != id ||
                expected.resourceType != resourceType)) {
      throw const DatasetApiFailure('invalid-publication-action');
    }
    if (!current()) throw const DatasetApiFailure('cancelled');
    final path =
        '/studio/v1/${resourceType}s/${Uri.encodeComponent(id)}'
        '/publication${action == null ? '' : '/$action'}';
    final headers = {'Authorization': 'Bearer $token'};
    final response =
        await (action == null
                ? client.get(base.resolve(path), headers: headers)
                : client.post(
                    base.resolve(path),
                    headers: {...headers, 'Content-Type': 'application/json'},
                    body: jsonEncode({
                      'revision': expected!.revision,
                      'fingerprint': expected.fingerprint,
                      'evidence': ?evidence,
                    }),
                  ))
            .timeout(const Duration(seconds: 30));
    if (!current()) throw const DatasetApiFailure('cancelled');
    if (response.statusCode == 401) {
      throw const DatasetApiFailure('session-expired');
    }
    if (response.statusCode == 403) {
      throw const DatasetApiFailure('forbidden');
    }
    if (response.statusCode == 412) {
      throw const DatasetApiFailure('publication-conflict');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DatasetApiFailure(
        response.statusCode == 422
            ? 'publication-invalid'
            : 'publication-unavailable',
      );
    }
    try {
      final review = PublicationReview.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
      if (review.id != id || review.resourceType != resourceType) {
        throw const FormatException();
      }
      return review;
    } on FormatException {
      throw const DatasetApiFailure('invalid-publication-review');
    } on TypeError {
      throw const DatasetApiFailure('invalid-publication-review');
    }
  }

  @override
  void close() => client.close();
}
