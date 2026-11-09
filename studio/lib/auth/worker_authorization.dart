import 'dart:convert';

import 'package:http/http.dart' as http;

import 'studio_session.dart';

class WorkerAuthorization implements StudioAuthorization {
  WorkerAuthorization(this.base, this.client) {
    if (base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        !(base.scheme == 'https' ||
            (base.scheme == 'http' &&
                {'localhost', '127.0.0.1'}.contains(base.host)))) {
      throw ArgumentError('Studio API requires HTTPS or loopback development');
    }
  }
  final Uri base;
  final http.Client client;
  @override
  Future<StudioPrincipal> lookup(String token) async {
    final response = await client
        .get(
          base.resolve('/content/v1/studio/session'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 403) throw const SessionFailure('forbidden');
    if (response.statusCode == 401) {
      throw const SessionFailure('session-expired');
    }
    if (response.statusCode != 200) {
      throw const SessionFailure('authorization-unavailable');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['uid'] is! String ||
        (data['uid'] as String).isEmpty ||
        data['email'] is! String ||
        !{'owner_admin', 'collector'}.contains(data['role'])) {
      throw const SessionFailure('authorization-unavailable');
    }
    return StudioPrincipal(
      data['uid'] as String,
      data['email'] as String,
      data['role'] as String,
    );
  }
}
