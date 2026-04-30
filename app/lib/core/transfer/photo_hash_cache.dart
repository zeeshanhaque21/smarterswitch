import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Persistent cache of (sha256, pHash) pairs keyed on `(uri, byteSize,
/// modifiedAtMs)`. The cache file lives in the app's support directory as
/// JSON and is loaded on construct, mutated in memory, and saved
/// explicitly via [save].
///
/// Why this matters: the sender's pre-flight pass reads the bytes of
/// every photo to compute sha256 + pHash. On a 30k-photo library that's
/// 2–4 minutes of compute on every transfer. A cache cuts subsequent
/// transfers' pre-flight cost to "iterate metadata + lookup" — sub-
/// second on the same 30k library. First transfer still pays the full
/// cost; second through Nth are nearly instant for unchanged files.
///
/// Invalidation: if `(byteSize, modifiedAtMs)` for a URI changes, the
/// cached entry is treated as a miss and recomputed. byteSize alone
/// would catch most edits (rewrite changes size); pairing with
/// MediaStore's DATE_MODIFIED makes it bulletproof for the rare
/// same-size edit.
class PhotoHashCache {
  PhotoHashCache._({required this.path, required Map<String, _Entry> entries})
      : _entries = entries;

  final String path;
  final Map<String, _Entry> _entries;
  bool _dirty = false;

  int get size => _entries.length;

  /// Open the cache file at `<dir>/photo_hash_cache.json`. Returns an
  /// empty cache if the file doesn't exist or fails to parse — fresh
  /// builds and corrupted caches both fall back gracefully to "compute
  /// from scratch."
  static Future<PhotoHashCache> open(String dir) async {
    final file = File('$dir/photo_hash_cache.json');
    final entries = <String, _Entry>{};
    if (await file.exists()) {
      try {
        final raw = jsonDecode(await file.readAsString())
            as Map<String, dynamic>;
        if (raw['version'] == 1) {
          final inner = (raw['entries'] as Map<String, dynamic>?) ?? const {};
          for (final e in inner.entries) {
            try {
              entries[e.key] = _Entry.fromJson(e.value as Map<String, dynamic>);
            } catch (_) {
              // Skip malformed entries; the rest of the cache is still good.
            }
          }
        }
      } catch (_) {
        // File is corrupted — start fresh. Don't delete it; save() will
        // overwrite cleanly.
      }
    }
    return PhotoHashCache._(path: file.path, entries: entries);
  }

  /// Lookup. Returns the cached pair iff the URI is known AND the
  /// (byteSize, modifiedAtMs) match. Otherwise null — caller should
  /// recompute and call [put] to refresh.
  CachedHashes? get(
    String uri, {
    required int byteSize,
    required int modifiedAtMs,
  }) {
    final entry = _entries[uri];
    if (entry == null) return null;
    if (entry.byteSize != byteSize) return null;
    if (entry.modifiedAtMs != modifiedAtMs) return null;
    return CachedHashes(sha256: entry.sha256, pHash: entry.pHash);
  }

  /// Insert or replace.
  void put(
    String uri, {
    required int byteSize,
    required int modifiedAtMs,
    required String sha256,
    int? pHash,
  }) {
    _entries[uri] = _Entry(
      byteSize: byteSize,
      modifiedAtMs: modifiedAtMs,
      sha256: sha256,
      pHash: pHash,
    );
    _dirty = true;
  }

  /// Drop entries whose URI isn't in [keep]. Called after a pre-flight
  /// pass to evict cached photos that were deleted from the device since
  /// last run, so the cache file doesn't grow unboundedly.
  void retainOnly(Set<String> keep) {
    final removed =
        _entries.keys.where((k) => !keep.contains(k)).toList();
    if (removed.isNotEmpty) {
      for (final k in removed) {
        _entries.remove(k);
      }
      _dirty = true;
    }
  }

  /// Persist the in-memory cache. No-op if no changes since last save.
  Future<void> save() async {
    if (!_dirty) return;
    final out = {
      'version': 1,
      'entries': {
        for (final e in _entries.entries) e.key: e.value.toJson(),
      },
    };
    try {
      await File(path).writeAsString(jsonEncode(out));
      _dirty = false;
    } catch (_) {
      // Persisting is best-effort; failure means next run repeats work.
    }
  }
}

class CachedHashes {
  const CachedHashes({required this.sha256, this.pHash});
  final String sha256;
  final int? pHash;
}

class _Entry {
  const _Entry({
    required this.byteSize,
    required this.modifiedAtMs,
    required this.sha256,
    this.pHash,
  });

  final int byteSize;
  final int modifiedAtMs;
  final String sha256;
  final int? pHash;

  Map<String, dynamic> toJson() => {
        'byteSize': byteSize,
        'modifiedAtMs': modifiedAtMs,
        'sha256': sha256,
        if (pHash != null) 'phash': pHash,
      };

  static _Entry fromJson(Map<String, dynamic> m) => _Entry(
        byteSize: (m['byteSize'] as num).toInt(),
        modifiedAtMs: (m['modifiedAtMs'] as num).toInt(),
        sha256: m['sha256'] as String,
        pHash: (m['phash'] as num?)?.toInt(),
      );
}
