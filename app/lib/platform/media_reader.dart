import 'package:flutter/services.dart';

import '../core/model/media_record.dart';

/// Dart wrapper for `smarterswitch/media` — read metadata, chunked file
/// reads/writes, and the existing count/summary surface used by the Select
/// screen.
class MediaReader {
  MediaReader({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('smarterswitch/media');
  final MethodChannel _channel;

  /// Chunk size used by sender-side reads and receiver-side writes. 256 KiB
  /// keeps each envelope well under the FrameCodec 64 MB cap, and keeps the
  /// per-chunk progress granularity good (a 4 MB photo = 16 chunks).
  static const int chunkBytes = 256 * 1024;

  Future<bool> hasReadPermission() async =>
      (await _channel.invokeMethod<bool>('hasReadPermission')) ?? false;

  Future<int> count() async =>
      (await _channel.invokeMethod<num>('count'))?.toInt() ?? 0;

  Future<MediaSummary> summary() async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>('summary');
    if (raw == null) return const MediaSummary(count: 0, totalBytes: 0);
    return MediaSummary(
      count: (raw['count'] as num?)?.toInt() ?? 0,
      totalBytes: (raw['totalBytes'] as num?)?.toInt() ?? 0,
    );
  }

  /// Per-file metadata for every photo + video on the device. Sender uses
  /// this as the work list; sha256 is computed lazily per-file to avoid a
  /// minutes-long upfront pass on a 30k-photo library.
  Future<List<MediaMetadata>> readMetadata() async {
    final raw = await _channel.invokeMethod<List<Object?>>('readMetadata');
    if (raw == null) return const [];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map((m) => MediaMetadata(
              uri: m['uri'] as String,
              fileName: m['fileName'] as String? ?? '',
              byteSize: (m['byteSize'] as num?)?.toInt() ?? 0,
              mimeType:
                  m['mimeType'] as String? ?? 'application/octet-stream',
              kind:
                  (m['kind'] as String?) == 'video' ? MediaKind.video : MediaKind.image,
              takenAtMs: (m['takenAtMs'] as num?)?.toInt(),
              modifiedAtMs: (m['modifiedAtMs'] as num?)?.toInt() ?? 0,
            ))
        .toList(growable: false);
  }

  Future<String> readSha256(String uri) async {
    return (await _channel.invokeMethod<String>(
          'readSha256',
          {'uri': uri},
        )) ??
        '';
  }

  /// Compute the perceptual hash of a photo. Returns null if the URI
  /// can't be decoded as an image (e.g. video, unsupported RAW format).
  /// The matcher in `core/dedup/photos_dedup.dart` uses this for fuzzy
  /// matches — a re-encoded copy of the same image differs in sha256
  /// but matches in pHash within a few Hamming-distance bits.
  Future<int?> computePHash(String uri) async {
    try {
      return await _channel.invokeMethod<int>('computePHash', {'uri': uri});
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> readChunk(String uri, int offset, int length) async {
    final bytes = await _channel.invokeMethod<Uint8List>(
      'readChunk',
      {'uri': uri, 'offset': offset, 'length': length},
    );
    return bytes ?? Uint8List(0);
  }

  /// Begin writing a file on the receiver. Opens the MediaStore output
  /// stream and stashes it keyed by sha256; subsequent writeChunk/writeEnd
  /// calls reference the same key.
  Future<bool> writeStart({
    required String sha256,
    required String fileName,
    required String mimeType,
    required MediaKind kind,
    int? takenAtMs,
  }) async {
    final ok = await _channel.invokeMethod<bool>(
      'writeStart',
      {
        'sha256': sha256,
        'fileName': fileName,
        'mimeType': mimeType,
        'kind': kind == MediaKind.video ? 'video' : 'image',
        'takenAtMs': takenAtMs,
      },
    );
    return ok ?? false;
  }

  Future<void> writeChunk(String sha256, Uint8List bytes) async {
    await _channel.invokeMethod<bool>(
      'writeChunk',
      {'sha256': sha256, 'bytes': bytes},
    );
  }

  Future<bool> writeEnd(String sha256) async {
    return (await _channel.invokeMethod<bool>(
          'writeEnd',
          {'sha256': sha256},
        )) ??
        false;
  }
}

class MediaMetadata {
  const MediaMetadata({
    required this.uri,
    required this.fileName,
    required this.byteSize,
    required this.mimeType,
    required this.kind,
    this.takenAtMs,
    this.modifiedAtMs = 0,
  });

  final String uri;
  final String fileName;
  final int byteSize;
  final String mimeType;
  final MediaKind kind;
  final int? takenAtMs;

  /// MediaStore.DATE_MODIFIED in ms. Used as the cache-invalidation key
  /// alongside byteSize — if either changes, recompute hashes.
  final int modifiedAtMs;
}

class MediaSummary {
  const MediaSummary({required this.count, required this.totalBytes});
  final int count;
  final int totalBytes;
}
