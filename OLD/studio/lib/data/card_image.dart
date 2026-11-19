import 'dart:convert';
import 'dart:typed_data';

/// A browser-local image candidate, never a remote image capability or binding.
/// Prepared candidates contain no remote capability or authorization.
class CardImage {
  CardImage({
    required this.filename,
    required this.mimeType,
    required this.base64,
    this.preparation,
  }) {
    if (filename.isEmpty ||
        filename.runes.any((rune) => rune < 0x20 || rune == 0x7f) ||
        !{'image/jpeg', 'image/png', 'image/webp'}.contains(mimeType) ||
        base64.length > ((maxBytes + 2) ~/ 3) * 4) {
      throw const FormatException('Invalid local image');
    }
    final decoded = bytes;
    if (decoded.isEmpty || decoded.length > maxBytes || !_signature(decoded)) {
      throw const FormatException('Invalid local image');
    }
  }

  static const maxBytes = 5 * 1024 * 1024;
  final String filename;
  final String mimeType;
  final String base64;
  final ImagePreparationInfo? preparation;
  bool get isPrepared => preparation != null;
  Uint8List get bytes => base64Decode(base64);

  String get suggestedName =>
      preparation?.suggestedName ?? imageNameSuggestion(filename);

  bool _signature(Uint8List data) => switch (mimeType) {
    'image/png' =>
      data.length >= 8 &&
          _prefix(data, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    'image/jpeg' => data.length >= 3 && _prefix(data, [0xff, 0xd8, 0xff]),
    'image/webp' =>
      data.length >= 12 &&
          _prefix(data, [0x52, 0x49, 0x46, 0x46]) &&
          data[8] == 0x57 &&
          data[9] == 0x45 &&
          data[10] == 0x42 &&
          data[11] == 0x50,
    _ => false,
  };

  static bool _prefix(Uint8List data, List<int> prefix) {
    for (var i = 0; i < prefix.length; i++) {
      if (data[i] != prefix[i]) return false;
    }
    return true;
  }

  Map<String, Object?> toJson() => {
    'filename': filename,
    'mimeType': mimeType,
    'base64': base64,
    if (preparation != null) 'preparation': preparation!.toJson(),
  };

  factory CardImage.fromJson(Map<String, Object?> json) {
    if (json.keys.toSet().difference({
          'filename',
          'mimeType',
          'base64',
          'preparation',
        }).isNotEmpty ||
        json['filename'] is! String ||
        json['mimeType'] is! String ||
        json['base64'] is! String ||
        json['preparation'] != null && json['preparation'] is! Map) {
      throw const FormatException('Invalid local image');
    }
    return CardImage(
      filename: json['filename']! as String,
      mimeType: json['mimeType']! as String,
      base64: json['base64']! as String,
      preparation: json['preparation'] == null
          ? null
          : ImagePreparationInfo.fromJson(
              Map<String, Object?>.from(json['preparation']! as Map),
            ),
    );
  }
}

/// Operational preparation details; never additional game product fields.
class ImagePreparationInfo {
  ImagePreparationInfo({
    required this.sha256,
    required this.width,
    required this.height,
    List<String> warnings = const [],
    this.suggestedName,
  }) : warnings = List.unmodifiable(warnings) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256) ||
        width < 1 ||
        height < 1 ||
        width > 4096 ||
        height > 4096 ||
        warnings.any((warning) => warning.isEmpty || warning.length > 512) ||
        warnings.length > 16 ||
        suggestedName != null &&
            (suggestedName!.isEmpty || suggestedName!.runes.any(_unsafeRune))) {
      throw const FormatException('Invalid image preparation metadata');
    }
  }
  final String sha256;
  final int width;
  final int height;
  final List<String> warnings;
  final String? suggestedName;
  Map<String, Object?> toJson() => {
    'sha256': sha256,
    'width': width,
    'height': height,
    'warnings': warnings,
    if (suggestedName != null) 'suggestedName': suggestedName,
  };
  factory ImagePreparationInfo.fromJson(Map<String, Object?> json) {
    if (json.keys.toSet().difference({
          'sha256',
          'width',
          'height',
          'warnings',
          'suggestedName',
        }).isNotEmpty ||
        json['sha256'] is! String ||
        json['width'] is! int ||
        json['height'] is! int ||
        json['warnings'] is! List ||
        (json['warnings']! as List).any((item) => item is! String) ||
        json['suggestedName'] != null && json['suggestedName'] is! String) {
      throw const FormatException('Invalid image preparation metadata');
    }
    return ImagePreparationInfo(
      sha256: json['sha256']! as String,
      width: json['width']! as int,
      height: json['height']! as int,
      warnings: List<String>.from(json['warnings']! as List),
      suggestedName: json['suggestedName'] as String?,
    );
  }
}

bool _unsafeRune(int rune) =>
    rune <= 0x1f ||
    rune >= 0x7f && rune <= 0x9f ||
    rune >= 0xd800 && rune <= 0xdfff;

String imageNameSuggestion(String filename) {
  final leaf = filename.split(RegExp(r'[/\\]')).last;
  final dot = leaf.lastIndexOf('.');
  final stem = dot > 0 ? leaf.substring(0, dot) : leaf;
  final cleaned = String.fromCharCodes(
    stem.runes.where((rune) => !_unsafeRune(rune)),
  ).replaceAll(RegExp(r'[_-]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return cleaned.isEmpty
      ? 'Untitled image'
      : String.fromCharCodes(cleaned.runes.take(120));
}
