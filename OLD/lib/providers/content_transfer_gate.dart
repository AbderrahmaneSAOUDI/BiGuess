import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One foreground content transfer/check across initial downloads and updates.
/// The owner releases only its own lease after cleanup and local projection.
final contentTransferOwnerProvider = StateProvider<Object?>((ref) => null);
