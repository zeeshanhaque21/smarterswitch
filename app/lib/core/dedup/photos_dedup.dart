import '../model/media_record.dart';

/// Photos and videos dedup matcher per ARCHITECTURE.md § core/dedup:
/// primary key sha256(file_bytes); secondary perceptual hash (pHash for
/// stills, video keyframe pHash) to catch resized/recompressed copies.
///
/// Two-tier behavior:
/// - sha256 match → silent dedup (the bytes are exactly identical).
/// - pHash within Hamming threshold but no sha256 match → conflict for
///   review (visually similar; the user decides keep-both vs replace).
/// - No match → new, transferred.
///
/// The hashes themselves are pre-computed by the platform reader (Kotlin
/// reads file bytes via MediaStore, computes both hashes off the main thread).
/// Keeping image-loading out of this file means the matcher is pure Dart and
/// fast to test.
class PhotosDedup {
  /// Default Hamming distance threshold for "perceptually similar". 8 of 64
  /// bits is a conservative number from the pHash literature: catches the
  /// resize/recompress case (typical Hamming distance: 0–4 bits) without
  /// false-positive matches on different photos shot of similar subjects
  /// (typical Hamming distance: ≥16 bits).
  static const int defaultPhashThreshold = 8;

  static PhotosDedupReport diff({
    required List<MediaRecord> source,
    required List<MediaRecord> target,
    int phashThreshold = defaultPhashThreshold,
  }) {
    // sha256 → exact dedup index.
    final targetBySha = <String, MediaRecord>{
      for (final t in target) t.sha256Hex.toLowerCase(): t,
    };
    // pHash list for the fuzzy-match pass. Records without a pHash are
    // skipped from the fuzzy pass (treated as sha256-only on both sides).
    final targetWithPhash =
        target.where((t) => t.pHash != null).toList(growable: false);

    final newRecords = <MediaRecord>[];
    final conflicts = <PhotoConflict>[];
    var exactDuplicates = 0;
    final seenSourceShas = <String>{};

    for (final s in source) {
      final sha = s.sha256Hex.toLowerCase();
      if (!seenSourceShas.add(sha)) continue; // source-side dupe
      if (targetBySha.containsKey(sha)) {
        exactDuplicates += 1;
        continue;
      }
      // No exact match. Try pHash if available on both sides.
      if (s.pHash != null) {
        PhotoConflict? best;
        for (final t in targetWithPhash) {
          final dist = hammingDistance64(s.pHash!, t.pHash!);
          if (dist > phashThreshold) continue;
          if (best == null || dist < best.hammingDistance) {
            best = PhotoConflict(
              source: s,
              candidate: t,
              hammingDistance: dist,
            );
          }
        }
        if (best != null) {
          conflicts.add(best);
          continue;
        }
      }
      newRecords.add(s);
    }

    return PhotosDedupReport(
      newRecords: List.unmodifiable(newRecords),
      conflicts: List.unmodifiable(conflicts),
      exactDuplicates: exactDuplicates,
      sourceTotal: source.length,
      targetTotal: target.length,
    );
  }

  /// Hamming distance between two 64-bit integers. Counts bits that differ.
  /// Exposed as a static helper so the conflict-review screen can also call
  /// it (e.g. to render "differs by 3 bits" hints).
  static int hammingDistance64(int a, int b) {
    var x = a ^ b;
    // Branchless popcount on a 64-bit int. Dart's `int` is 64-bit on ARM/x86.
    x = x - ((x >> 1) & 0x5555555555555555);
    x = (x & 0x3333333333333333) + ((x >> 2) & 0x3333333333333333);
    x = (x + (x >> 4)) & 0x0f0f0f0f0f0f0f0f;
    return ((x * 0x0101010101010101) >> 56) & 0x7f;
  }
}

class PhotoConflict {
  const PhotoConflict({
    required this.source,
    required this.candidate,
    required this.hammingDistance,
  });

  final MediaRecord source;
  final MediaRecord candidate;

  /// Bits-differing between the two pHashes. 0 = pHash-identical (rare
  /// without sha256 also matching, but possible for pixel-equal images
  /// re-encoded with different metadata). Higher = less similar.
  final int hammingDistance;
}

class PhotosDedupReport {
  const PhotosDedupReport({
    required this.newRecords,
    required this.conflicts,
    required this.exactDuplicates,
    required this.sourceTotal,
    required this.targetTotal,
  });

  final List<MediaRecord> newRecords;

  /// pHash-only matches. Surfaced to the conflict review screen.
  final List<PhotoConflict> conflicts;

  final int exactDuplicates;
  final int sourceTotal;
  final int targetTotal;

  int get newCount => newRecords.length;
  int get conflictCount => conflicts.length;
}
