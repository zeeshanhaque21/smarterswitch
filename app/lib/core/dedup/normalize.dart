/// Normalization helpers shared by every dedup matcher.
///
/// Why this exists: carriers, devices, and apps all introduce small lossy
/// variations to the "same" record (extra whitespace in SMS bodies, different
/// formatting of phone numbers, ±1 minute timestamp jitter). The dedup engine
/// runs on normalized values so identical-but-formatted-differently records
/// hash the same.
library;

/// Strip everything except digits, then collapse the very common US case where
/// the same number appears as both `+1XXXXXXXXXX` and `XXXXXXXXXX`. Both forms
/// reduce to the bare 10-digit `XXXXXXXXXX`.
///
/// Examples:
/// - `(415) 555-1212`, `415-555-1212`, `+1 415 555 1212`, `4155551212` → `4155551212`
/// - `+447700900123` → `447700900123` (UK; no special-cased trim — we'd need locale)
/// - `12345` (short code) → `12345`
///
/// Phase 1 limitation: only the US country-code drop is implemented. For other
/// locales, `+XX YYY` and `YYY` will *not* match. This is a known gap; full
/// libphonenumber-grade normalization is deferred until we ship outside the US.
String normalizeAddress(String raw) {
  final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.length == 11 && digits.startsWith('1')) {
    return digits.substring(1);
  }
  return digits;
}

/// Collapse runs of whitespace and trim. SMS bodies are surprisingly often
/// `"hello"` vs `"hello "` vs `"hello\r\n"` due to differing exporters.
String normalizeBody(String raw) {
  return raw.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Bucket a millisecond timestamp to its containing minute. Carriers and
/// devices can disagree by up to ~30 seconds on the same message; bucketing
/// to the minute absorbs that without merging genuinely-distinct messages
/// (you don't send the same person the same text twice in the same minute).
int bucketTimestampToMinute(int timestampMs) {
  return timestampMs - (timestampMs % 60000);
}

/// Lower-case + whitespace-collapse + trim. Used for human-typed strings
/// where capitalization shouldn't matter for identity (calendar titles,
/// locations, contact names). Distinct from `normalizeBody` (case-sensitive)
/// because SMS bodies *are* case-sensitive — "yes" and "YES" are different
/// messages — while "Lunch with Alice" and "lunch with alice" are obviously
/// the same calendar event.
String normalizeTextCaseInsensitive(String raw) {
  return raw.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Email normalization: lowercase the whole address, trim. Strict by design
/// — we don't strip `+tag` aliases or normalize subdomain variations because
/// users intentionally use those as different addresses for filtering.
String normalizeEmail(String raw) {
  return raw.toLowerCase().trim();
}
