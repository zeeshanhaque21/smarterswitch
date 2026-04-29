import '../model/call_log_record.dart';
import 'normalize.dart';

/// Composite-key dedup matcher for call logs, per ARCHITECTURE.md § core/dedup:
/// `(normalized_number, timestamp_to_minute, duration_seconds, direction)`.
///
/// Why duration is in the key: two calls from the same person at the same
/// minute with different durations are genuinely distinct events (e.g. a
/// 5-second hang-up followed by a 3-minute callback). Matching on minute
/// alone would collapse those into one.
class CallLogDedup {
  static CallLogDedupKey keyFor(CallLogRecord r) {
    return CallLogDedupKey(
      number: normalizeAddress(r.number),
      timestampMinute: bucketTimestampToMinute(r.timestampMs),
      durationSeconds: r.durationSeconds,
      direction: r.direction,
    );
  }

  static Set<CallLogDedupKey> indexOf(Iterable<CallLogRecord> records) {
    return {for (final r in records) keyFor(r)};
  }

  static bool isDuplicate(Set<CallLogDedupKey> index, CallLogRecord incoming) {
    return index.contains(keyFor(incoming));
  }

  /// Diff a sender batch against a receiver batch. Returns the records that
  /// would be transferred (the misses) and the count of duplicates skipped.
  static CallLogDedupReport diff({
    required List<CallLogRecord> source,
    required List<CallLogRecord> target,
  }) {
    final targetIndex = indexOf(target);
    final newRecords = <CallLogRecord>[];
    var duplicates = 0;
    final seenInSource = <CallLogDedupKey>{};
    for (final r in source) {
      final k = keyFor(r);
      if (!seenInSource.add(k)) continue;
      if (targetIndex.contains(k)) {
        duplicates += 1;
      } else {
        newRecords.add(r);
      }
    }
    return CallLogDedupReport(
      newRecords: List.unmodifiable(newRecords),
      duplicatesSkipped: duplicates,
      sourceTotal: source.length,
      targetTotal: target.length,
    );
  }
}

class CallLogDedupKey {
  const CallLogDedupKey({
    required this.number,
    required this.timestampMinute,
    required this.durationSeconds,
    required this.direction,
  });

  final String number;
  final int timestampMinute;
  final int durationSeconds;
  final CallDirection direction;

  @override
  bool operator ==(Object other) {
    if (other is! CallLogDedupKey) return false;
    return number == other.number &&
        timestampMinute == other.timestampMinute &&
        durationSeconds == other.durationSeconds &&
        direction == other.direction;
  }

  @override
  int get hashCode =>
      Object.hash(number, timestampMinute, durationSeconds, direction);

  @override
  String toString() =>
      'CallLogDedupKey($number @ $timestampMinute, ${durationSeconds}s, $direction)';
}

class CallLogDedupReport {
  const CallLogDedupReport({
    required this.newRecords,
    required this.duplicatesSkipped,
    required this.sourceTotal,
    required this.targetTotal,
  });

  final List<CallLogRecord> newRecords;
  final int duplicatesSkipped;
  final int sourceTotal;
  final int targetTotal;

  int get newCount => newRecords.length;
}
