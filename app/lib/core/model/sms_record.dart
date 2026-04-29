/// A single SMS or MMS record, normalized into a platform-agnostic form before
/// being fed to the dedup engine.
///
/// Pure data — no platform dependencies — so it can be unit-tested without a
/// device.
class SmsRecord {
  const SmsRecord({
    required this.address,
    required this.body,
    required this.timestampMs,
    required this.type,
    this.threadId,
    this.mmsParts = const [],
  });

  /// Phone number or short code as reported by the source. Not yet normalized;
  /// the dedup engine normalizes lazily.
  final String address;

  /// Plain-text body. For MMS, this is the text part; binary parts go in
  /// [mmsParts].
  final String body;

  /// Source-reported send/receive time, in milliseconds since Unix epoch.
  final int timestampMs;

  final SmsType type;

  /// Source-side thread identifier. Useful for reconstructing conversations on
  /// the target but not used by dedup matching.
  final int? threadId;

  /// SHA-256 of each MMS attachment's bytes. Empty for plain SMS.
  final List<String> mmsParts;
}

enum SmsType { inbox, sent, draft, outbox, failed, queued }
