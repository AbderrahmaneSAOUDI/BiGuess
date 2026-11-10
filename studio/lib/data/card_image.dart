import 'dart:convert';
import 'dart:typed_data';

/// A browser-local image candidate, never a remote image capability or binding.
/// Normalization and authenticated ingestion are separate later workflows.
class CardImage {
  CardImage({
    required this.filename,
    required this.mimeType,
    required this.base64,
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
  Uint8List get bytes => base64Decode(base64);

  String get suggestedName {
    final leaf = filename.split(RegExp(r'[/\\]')).last;
    final dot = leaf.lastIndexOf('.');
    return (dot > 0 ? leaf.substring(0, dot) : leaf)
        .replaceAll(RegExp(r'[_-]+'), ' ')
        .trim();
  }

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
  };

  factory CardImage.fromJson(Map<String, Object?> json) {
    if (json.keys.toSet().difference({
          'filename',
          'mimeType',
          'base64',
        }).isNotEmpty ||
        json['filename'] is! String ||
        json['mimeType'] is! String ||
        json['base64'] is! String) {
      throw const FormatException('Invalid local image');
    }
    return CardImage(
      filename: json['filename']! as String,
      mimeType: json['mimeType']! as String,
      base64: json['base64']! as String,
    );
  }
}
