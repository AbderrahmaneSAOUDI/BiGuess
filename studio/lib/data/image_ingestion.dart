import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'card_image.dart';
import 'dataset_api.dart';

/// A private Pack binding, not a public URL or authority to publish content.
class UploadedCardImage {
  UploadedCardImage({
    required this.packId,
    required this.imageReference,
    required this.sha256,
    required this.byteLength,
    required this.contentType,
    required this.width,
    required this.height,
  }) {
    final extension = contentType == 'image/webp' ? 'webp' : 'png';
    if (packId.isEmpty ||
        !{'image/webp', 'image/png'}.contains(contentType) ||
        !RegExp(r'^objects/[a-f0-9]{64}\.' + extension + r'$')
            .hasMatch(imageReference) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256) ||
        byteLength < 1 ||
        byteLength > CardImage.maxBytes ||
        width < 1 ||
        height < 1 ||
        width > 1024 ||
        height > 1024) {
      throw const FormatException('Invalid image upload receipt');
    }
  }
  final String packId;
  final String imageReference;
  final String sha256;
  final int byteLength;
  final String contentType;
  final int width;
  final int height;

  bool matches(String pack, CardImage image) =>
      packId == pack &&
      image.preparation?.sha256 == sha256 &&
      image.mimeType == contentType &&
      image.bytes.length == byteLength &&
      image.preparation?.width == width &&
      image.preparation?.height == height;

  Map<String, Object?> toJson() => {
    'protocolVersion': 1,
    'imageIngestionVersion': 1,
    'packId': packId,
    'imageReference': imageReference,
    'sha256': sha256,
    'byteLength': byteLength,
    'contentType': contentType,
    'width': width,
    'height': height,
  };
  factory UploadedCardImage.fromJson(Map<String, Object?> json) {
    const keys = {
      'protocolVersion',
      'imageIngestionVersion',
      'packId',
      'imageReference',
      'sha256',
      'byteLength',
      'contentType',
      'width',
      'height',
    };
    if (json.length != keys.length ||
        json.keys.any((k) => !keys.contains(k)) ||
        json['protocolVersion'] != 1 ||
        json['imageIngestionVersion'] != 1 ||
        json['packId'] is! String ||
        json['imageReference'] is! String ||
        json['sha256'] is! String ||
        json['byteLength'] is! int ||
        json['contentType'] is! String ||
        json['width'] is! int ||
        json['height'] is! int) {
      throw const FormatException('Invalid image upload receipt');
    }
    return UploadedCardImage(
      packId: json['packId']! as String,
      imageReference: json['imageReference']! as String,
      sha256: json['sha256']! as String,
      byteLength: json['byteLength']! as int,
      contentType: json['contentType']! as String,
      width: json['width']! as int,
      height: json['height']! as int,
    );
  }
}

abstract interface class ImageIngestionApi {
  Future<UploadedCardImage> upload(
    String token,
    String packId,
    int revision,
    CardImage image,
    bool Function() current, {
    required Future<void> cancelled,
  });
  void close();
}

class WorkerImageIngestionApi implements ImageIngestionApi {
  WorkerImageIngestionApi(this.base, this.client);
  final Uri base;
  final http.Client client;
  @override
  Future<UploadedCardImage> upload(
    String token,
    String packId,
    int revision,
    CardImage image,
    bool Function() current, {
    required Future<void> cancelled,
  }) async {
    if (!current()) throw const DatasetApiFailure('cancelled');
    final prepared = image.preparation;
    if (prepared == null ||
        !{'image/webp', 'image/png'}.contains(image.mimeType)) {
      throw const DatasetApiFailure('image-not-prepared');
    }
    final abort = Completer<void>();
    void cancel() {
      if (!abort.isCompleted) abort.complete();
    }

    unawaited(cancelled.then((_) => cancel()));
    final timer = Timer(const Duration(seconds: 30), cancel);
    try {
      final uri = base.resolve(
        '/studio/v1/packs/${Uri.encodeComponent(packId)}/images',
      );
      final request =
          http.AbortableRequest('POST', uri, abortTrigger: abort.future)
            ..headers.addAll({
              'Authorization': 'Bearer $token',
              'Content-Type': image.mimeType,
              'X-Content-SHA256': prepared.sha256,
              'If-Match': '"rev-$revision"',
            })
            ..bodyBytes = image.bytes;
      final response = await http.Response.fromStream(
        await client.send(request),
      );
      if (!current()) throw const DatasetApiFailure('cancelled');
      if (response.statusCode != 200) {
        String? serverCode;
        try {
          final error = jsonDecode(response.body);
          if (error is Map &&
              error['protocolVersion'] == 1 &&
              error['error'] is Map) {
            final code = (error['error'] as Map)['code'];
            if (code is String) serverCode = code;
          }
        } on FormatException {
          // Status-based recovery also works with a truncated error response.
        }
        final code = switch (response.statusCode) {
          401 => 'session-expired',
          403 => 'forbidden',
          404 => 'image-pack-unavailable',
          412 => 'draft-conflict',
          413 => 'image-too-large',
          429 when serverCode == 'rate_limited' => 'image-upload-busy',
          429 => 'image-quota',
          408 => 'image-upload-interrupted',
          400 when serverCode == 'upload_interrupted' =>
            'image-upload-interrupted',
          400 || 415 || 422 => 'image-rejected',
          _ => 'image-upload-unavailable',
        };
        throw DatasetApiFailure(code);
      }
      try {
        final receipt = UploadedCardImage.fromJson(
          Map<String, Object?>.from(jsonDecode(response.body) as Map),
        );
        if (!receipt.matches(packId, image)) throw const FormatException();
        return receipt;
      } on FormatException {
        throw const DatasetApiFailure('invalid-image-receipt');
      } on TypeError {
        throw const DatasetApiFailure('invalid-image-receipt');
      }
    } on http.RequestAbortedException {
      throw DatasetApiFailure(
        current() ? 'image-upload-interrupted' : 'cancelled',
      );
    } on http.ClientException {
      throw const DatasetApiFailure('image-upload-unavailable');
    } finally {
      timer.cancel();
      cancel();
    }
  }

  @override
  void close() => client.close();
}
