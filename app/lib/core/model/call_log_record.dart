/// Single call log entry, normalized into a platform-agnostic form before
/// being fed to the call-log dedup engine.
class CallLogRecord {
  const CallLogRecord({
    required this.number,
    required this.timestampMs,
    required this.durationSeconds,
    required this.direction,
    this.cachedName,
  });

  /// Phone number as reported by the source. Not yet normalized; the dedup
  /// engine normalizes via [normalizeAddress].
  final String number;

  /// Start time, in milliseconds since Unix epoch.
  final int timestampMs;

  /// Call duration in seconds. 0 for missed/rejected calls.
  final int durationSeconds;

  final CallDirection direction;

  /// Optional contact name cached at call time. Not part of the dedup key —
  /// the same call from a Samsung phone vs a Pixel may have different cached
  /// names depending on each device's contact resolution at the time. Carried
  /// through so the receiver can display it; ignored by the matcher.
  final String? cachedName;
}

/// Maps to AOSP `CallLog.Calls.TYPE` constants. We surface only the four
/// distinctions that affect dedup: in/out/missed/rejected. Voicemail and
/// blocked types collapse into [missed] for matching purposes (they're both
/// "I didn't pick up" from the user's perspective).
enum CallDirection { incoming, outgoing, missed, rejected }
