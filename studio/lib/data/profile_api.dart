import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/studio_session.dart';
import 'dataset_api.dart';

/// Lifetime activity, not a count of currently visible content or local drafts.
class ContributionCounts {
  ContributionCounts(Map<String, dynamic> json)
    : values = Map.unmodifiable({
        for (final key in labels.keys) key: _count(json[key]),
      }) {
    if (json.length != labels.length ||
        values['totalOperations'] !=
            values.entries
                .where((e) => e.key != 'totalOperations')
                .fold<int>(0, (sum, e) => sum + e.value)) {
      throw const FormatException('Invalid contribution totals');
    }
  }
  final Map<String, int> values;
  static const labels = {
    'totalOperations': 'Validated operations',
    'topicsCreated': 'Topics created',
    'topicsRemoved': 'Topics removed',
    'packsCreated': 'Packs created',
    'packsRemoved': 'Packs removed',
    'cardsAdded': 'Cards added',
    'cardsRemoved': 'Cards removed',
    'edits': 'Edits',
    'hides': 'Hides',
    'restores': 'Restorations',
    'permanentDeletes': 'Permanent deletions',
    'activations': 'Activations',
  };
}

class ContributorSummary {
  ContributorSummary.fromJson(Map<String, dynamic> json)
    : uid = _text(json['uid']),
      email = json['email'] == null ? null : _text(json['email']),
      role = json['role'] == null ? null : _role(json['role']),
      counts = ContributionCounts(_object(json['counts']));
  final String uid;
  final String? email;
  final String? role;
  final ContributionCounts counts;
}

class ContributionActivity {
  ContributionActivity.fromJson(Map<String, dynamic> json)
    : batchId = _text(json['batchId']),
      actorId = _text(json['actorId']),
      actorRole = _role(json['actorRole']),
      resourceType = _text(json['resourceType']),
      resourceId = _text(json['resourceId']),
      action = _text(json['action']),
      revision = _count(json['revision']),
      committedAt = DateTime.parse(_text(json['committedAt'])) {
    if (!{'topic', 'pack', 'card'}.contains(resourceType) ||
        revision < 1 ||
        !{
          'create',
          'update',
          'hide',
          'activate',
          'softDelete',
          'restore',
          'permanentDelete',
        }.contains(action)) {
      throw const FormatException('Invalid activity');
    }
  }
  final String batchId, actorId, actorRole, resourceType, resourceId, action;
  final int revision;
  final DateTime committedAt;
  String get key => jsonEncode([batchId, resourceType, resourceId]);
}

class ContributorProfile {
  ContributorProfile({
    required this.principal,
    required this.counts,
    required this.contributors,
    required this.activity,
    required this.asOf,
    required this.contributorUid,
    required this.nextCursor,
  });
  final StudioPrincipal principal;
  final ContributionCounts counts;
  final List<ContributorSummary> contributors;
  final List<ContributionActivity> activity;
  final DateTime asOf;
  final String? contributorUid, nextCursor;

  factory ContributorProfile.fromJson(Map<String, dynamic> json) {
    if (json['protocolVersion'] != 1 ||
        json['scopeVersion'] != 1 ||
        json['contributors'] is! List ||
        json['activity'] is! List ||
        (json['nextCursor'] != null &&
            (json['nextCursor'] is! String ||
                (json['nextCursor'] as String).isEmpty)) ||
        (json['contributorUid'] != null && json['contributorUid'] is! String)) {
      throw const FormatException('Invalid profile');
    }
    final identity = _object(json['principal']);
    final principal = StudioPrincipal(
      _text(identity['uid']),
      _text(identity['email']),
      _role(identity['role']),
    );
    final contributors = (json['contributors'] as List)
        .map((v) => ContributorSummary.fromJson(_object(v)))
        .toList();
    final activity = (json['activity'] as List)
        .map((v) => ContributionActivity.fromJson(_object(v)))
        .toList();
    final filter = json['contributorUid'] as String?;
    if (contributors.map((c) => c.uid).toSet().length != contributors.length ||
        activity.map((a) => a.key).toSet().length != activity.length ||
        principal.role == 'collector' &&
            (contributors.isNotEmpty ||
                filter != null ||
                activity.any((a) => a.actorId != principal.uid)) ||
        filter != null && activity.any((a) => a.actorId != filter)) {
      throw const FormatException('Invalid profile scope');
    }
    return ContributorProfile(
      principal: principal,
      counts: ContributionCounts(_object(json['counts'])),
      contributors: List.unmodifiable(contributors),
      activity: List.unmodifiable(activity),
      asOf: DateTime.parse(_text(json['asOf'])),
      contributorUid: filter,
      nextCursor: json['nextCursor'] as String?,
    );
  }

  ContributorProfile append(ContributorProfile page) {
    if (page.principal.uid != principal.uid ||
        page.principal.role != principal.role ||
        page.contributorUid != contributorUid ||
        page.asOf != asOf ||
        jsonEncode(page.counts.values) != jsonEncode(counts.values) ||
        page.activity.any((a) => activity.any((old) => old.key == a.key))) {
      throw const DatasetApiFailure('invalid-profile');
    }
    return ContributorProfile(
      principal: principal,
      counts: counts,
      contributors: contributors,
      activity: List.unmodifiable([...activity, ...page.activity]),
      asOf: asOf,
      contributorUid: contributorUid,
      nextCursor: page.nextCursor,
    );
  }
}

abstract interface class ProfileApi {
  Future<ContributorProfile> read(
    String token,
    bool Function() current, {
    String? contributorUid,
    String? cursor,
  });
  void close();
}

class WorkerProfileApi implements ProfileApi {
  WorkerProfileApi(this.base, this.client);
  final Uri base;
  final http.Client client;
  @override
  Future<ContributorProfile> read(
    String token,
    bool Function() current, {
    String? contributorUid,
    String? cursor,
  }) async {
    if (!current()) throw const DatasetApiFailure('cancelled');
    final uri = base
        .resolve('/studio/v1/profile')
        .replace(
          queryParameters: {
            'limit': '50',
            'contributorUid': ?contributorUid,
            'cursor': ?cursor,
          },
        );
    final response = await client
        .get(uri, headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 20));
    if (!current()) throw const DatasetApiFailure('cancelled');
    if (response.statusCode != 200) {
      throw DatasetApiFailure(switch (response.statusCode) {
        401 => 'session-expired',
        403 => 'forbidden',
        409 => 'cursor_expired',
        _ => 'profile-unavailable',
      });
    }
    try {
      return ContributorProfile.fromJson(_object(jsonDecode(response.body)));
    } on FormatException {
      throw const DatasetApiFailure('invalid-profile');
    } on TypeError {
      throw const DatasetApiFailure('invalid-profile');
    }
  }

  @override
  void close() => client.close();
}

Map<String, dynamic> _object(Object? value) =>
    Map<String, dynamic>.from(value as Map);
String _text(Object? value) {
  if (value is! String || value.isEmpty) {
    throw const FormatException('Expected text');
  }
  return value;
}

String _role(Object? value) {
  if (!{'collector', 'owner_admin'}.contains(value)) {
    throw const FormatException('Invalid role');
  }
  return value! as String;
}

int _count(Object? value) {
  if (value is! int || value < 0 || value > 9007199254740991) {
    throw const FormatException('Invalid count');
  }
  return value;
}
