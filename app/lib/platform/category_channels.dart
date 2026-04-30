/// Thin Dart wrappers for the per-category MethodChannels. Each one exposes
/// the minimum surface the Select screen needs: a permission probe and a
/// count. Full read/write methods are added per-channel as each category's
/// transfer code lands.
///
/// The wrappers exist as separate classes (rather than one big "PlatformApi")
/// so the imports stay narrow and so dependency-injection in tests is
/// straightforward — pass a fake channel into one wrapper at a time.
library;

import 'package:flutter/services.dart';

// CallLogReader, ContactsReader, and CalendarReader live in their own files
// (lib/platform/<category>_reader.dart). They each grew a readAll/writeAll
// surface that doesn't fit the count-only shape of the wrappers below.

class MediaReader {
  MediaReader({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('smarterswitch/media');
  final MethodChannel _channel;

  Future<bool> hasReadPermission() async =>
      (await _channel.invokeMethod<bool>('hasReadPermission')) ?? false;

  Future<int> count() async =>
      (await _channel.invokeMethod<num>('count'))?.toInt() ?? 0;

  /// Returns `(count, totalBytes)`. Used on the Select screen to render an
  /// estimated transfer size for photos/videos — the only category where the
  /// byte total is large enough to be worth surfacing pre-transfer.
  Future<MediaSummary> summary() async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>('summary');
    if (raw == null) return const MediaSummary(count: 0, totalBytes: 0);
    return MediaSummary(
      count: (raw['count'] as num?)?.toInt() ?? 0,
      totalBytes: (raw['totalBytes'] as num?)?.toInt() ?? 0,
    );
  }
}

class MediaSummary {
  const MediaSummary({required this.count, required this.totalBytes});
  final int count;
  final int totalBytes;
}
