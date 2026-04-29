/// Single photo or video, normalized into a platform-agnostic form before
/// being fed to the photos dedup engine.
///
/// Hashes are pre-computed by the platform reader (Kotlin reads bytes via
/// `MediaStore`, computes sha256 + pHash off the main thread, streams results
/// back via an EventChannel). The matcher in `photos_dedup.dart` operates on
/// records that already have both hashes filled in — keeping the matcher
/// pure-Dart and unit-testable.
class MediaRecord {
  const MediaRecord({
    required this.uri,
    required this.fileName,
    required this.byteSize,
    required this.kind,
    required this.sha256Hex,
    this.pHash,
    this.takenAtMs,
  });

  /// Stable identifier on the source side. For Android this is the
  /// MediaStore content URI; for iOS, a PhotoKit local-identifier.
  final String uri;

  final String fileName;
  final int byteSize;
  final MediaKind kind;

  /// SHA-256 of the file bytes, hex-encoded. Lower-cased.
  final String sha256Hex;

  /// 64-bit perceptual hash. Null for videos in v1 (video pHash needs keyframe
  /// extraction; arrives in a follow-up). Null for images that fail to load.
  final int? pHash;

  /// EXIF DateTimeOriginal (or video creation time) in ms since epoch, when
  /// available. Carried through but not part of the matching key — pHash +
  /// sha256 are enough.
  final int? takenAtMs;
}

enum MediaKind { image, video }
