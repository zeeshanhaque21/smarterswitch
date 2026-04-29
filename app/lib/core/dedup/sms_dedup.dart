import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../model/sms_record.dart';
import 'normalize.dart';

/// Composite-hash dedup matcher for SMS/MMS, per ARCHITECTURE.md § core/dedup.
///
/// Key components: `(normalized_address, timestamp_to_minute, body_sha256, mms_part_hashes)`.
/// Anything else (thread id, source-reported type, draft state) is excluded so
/// that the same message exported from two devices hashes identically even when
/// surrounding metadata differs.
class SmsDedup {
  /// Builds a [SmsDedupKey] for a single record. Exposed (not just `compare`-style)
  /// so callers can pre-hash the source manifest, send only hashes over the wire,
  /// and pull full payloads only for misses — see ARCHITECTURE.md "manifest then payload."
  static SmsDedupKey keyFor(SmsRecord record) {
    final addr = normalizeAddress(record.address);
    final bodyHash = sha256.convert(utf8.encode(normalizeBody(record.body))).toString();
    final ts = bucketTimestampToMinute(record.timestampMs);
    final partHashes = [...record.mmsParts]..sort();
    return SmsDedupKey(
      address: addr,
      timestampMinute: ts,
      bodyHash: bodyHash,
      mmsPartHashes: List.unmodifiable(partHashes),
    );
  }

  /// Build an index of dedup keys from a set of records. Repeated calls with
  /// the same record produce the same key, so the index size equals the count
  /// of *distinct* messages (this is what the receiver builds before scanning
  /// the sender's manifest).
  static Set<SmsDedupKey> indexOf(Iterable<SmsRecord> records) {
    return {for (final r in records) keyFor(r)};
  }

  /// Given the receiver's index and an incoming sender record, true iff a
  /// match exists. The default behavior — used during transfer — is "skip on
  /// match, write on miss."
  static bool isDuplicate(Set<SmsDedupKey> index, SmsRecord incoming) {
    return index.contains(keyFor(incoming));
  }

  /// Diff a sender batch against a receiver batch. Returns the records that
  /// would be transferred (the misses) and the count of duplicates skipped.
  /// This is the function the validation harness in Phase 1 calls.
  static SmsDedupReport diff({
    required List<SmsRecord> source,
    required List<SmsRecord> target,
  }) {
    final targetIndex = indexOf(target);
    final newRecords = <SmsRecord>[];
    var duplicates = 0;
    final seenInSource = <SmsDedupKey>{};
    for (final r in source) {
      final k = keyFor(r);
      if (!seenInSource.add(k)) {
        // Source-side duplicate — collapse to one transfer attempt.
        continue;
      }
      if (targetIndex.contains(k)) {
        duplicates += 1;
      } else {
        newRecords.add(r);
      }
    }
    return SmsDedupReport(
      newRecords: List.unmodifiable(newRecords),
      duplicatesSkipped: duplicates,
      sourceTotal: source.length,
      targetTotal: target.length,
    );
  }
}

class SmsDedupKey {
  const SmsDedupKey({
    required this.address,
    required this.timestampMinute,
    required this.bodyHash,
    required this.mmsPartHashes,
  });

  final String address;
  final int timestampMinute;
  final String bodyHash;
  final List<String> mmsPartHashes;

  @override
  bool operator ==(Object other) {
    if (other is! SmsDedupKey) return false;
    if (address != other.address) return false;
    if (timestampMinute != other.timestampMinute) return false;
    if (bodyHash != other.bodyHash) return false;
    if (mmsPartHashes.length != other.mmsPartHashes.length) return false;
    for (var i = 0; i < mmsPartHashes.length; i++) {
      if (mmsPartHashes[i] != other.mmsPartHashes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        address,
        timestampMinute,
        bodyHash,
        Object.hashAll(mmsPartHashes),
      );

  @override
  String toString() =>
      'SmsDedupKey($address @ $timestampMinute, body=${bodyHash.substring(0, 8)}…, parts=${mmsPartHashes.length})';
}

class SmsDedupReport {
  const SmsDedupReport({
    required this.newRecords,
    required this.duplicatesSkipped,
    required this.sourceTotal,
    required this.targetTotal,
  });

  final List<SmsRecord> newRecords;
  final int duplicatesSkipped;
  final int sourceTotal;
  final int targetTotal;

  int get newCount => newRecords.length;
}
