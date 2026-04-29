import '../model/calendar_event.dart';
import 'normalize.dart';

/// Calendar dedup matcher per ARCHITECTURE.md § core/dedup:
/// `(uid)` if present, else `(start_utc, duration, title_normalized, location_normalized)`.
///
/// Two-tier strategy:
/// - UID match is exact and trumps everything. Two events with the same UID
///   are by definition the same event (CalDAV/iCal spec).
/// - For UID-less events (locally created on-device), match on the composite
///   key. Title and location use case-insensitive whitespace-collapse so
///   "Lunch with Alice" matches "lunch with alice  " — humans don't care.
class CalendarDedup {
  static CalendarDedupKey keyFor(CalendarEvent e) {
    if (e.uid != null && e.uid!.isNotEmpty) {
      return CalendarDedupKey.uidOnly(e.uid!);
    }
    return CalendarDedupKey.composite(
      startUtcMs: e.startUtcMs,
      durationMs: e.durationMs,
      title: normalizeTextCaseInsensitive(e.title),
      location: normalizeTextCaseInsensitive(e.location),
    );
  }

  static Set<CalendarDedupKey> indexOf(Iterable<CalendarEvent> events) {
    return {for (final e in events) keyFor(e)};
  }

  static bool isDuplicate(Set<CalendarDedupKey> index, CalendarEvent e) {
    return index.contains(keyFor(e));
  }

  static CalendarDedupReport diff({
    required List<CalendarEvent> source,
    required List<CalendarEvent> target,
  }) {
    final targetIndex = indexOf(target);
    final newEvents = <CalendarEvent>[];
    var duplicates = 0;
    final seenInSource = <CalendarDedupKey>{};
    for (final e in source) {
      final k = keyFor(e);
      if (!seenInSource.add(k)) continue;
      if (targetIndex.contains(k)) {
        duplicates += 1;
      } else {
        newEvents.add(e);
      }
    }
    return CalendarDedupReport(
      newEvents: List.unmodifiable(newEvents),
      duplicatesSkipped: duplicates,
      sourceTotal: source.length,
      targetTotal: target.length,
    );
  }
}

/// Sum-type key: either a UID or a composite. Equal across kinds is impossible
/// (a UID-only key never equals a composite even if their fields happen to
/// collide), which keeps the two paths cleanly separated.
class CalendarDedupKey {
  const CalendarDedupKey.uidOnly(this.uid)
      : startUtcMs = 0,
        durationMs = 0,
        title = '',
        location = '';

  const CalendarDedupKey.composite({
    required this.startUtcMs,
    required this.durationMs,
    required this.title,
    required this.location,
  }) : uid = null;

  final String? uid;
  final int startUtcMs;
  final int durationMs;
  final String title;
  final String location;

  bool get _isUidKey => uid != null;

  @override
  bool operator ==(Object other) {
    if (other is! CalendarDedupKey) return false;
    if (_isUidKey != other._isUidKey) return false;
    if (_isUidKey) return uid == other.uid;
    return startUtcMs == other.startUtcMs &&
        durationMs == other.durationMs &&
        title == other.title &&
        location == other.location;
  }

  @override
  int get hashCode => _isUidKey
      ? Object.hash('uid', uid)
      : Object.hash('comp', startUtcMs, durationMs, title, location);

  @override
  String toString() => _isUidKey
      ? 'CalendarDedupKey(uid=$uid)'
      : 'CalendarDedupKey($title @ $startUtcMs, ${durationMs}ms, loc=$location)';
}

class CalendarDedupReport {
  const CalendarDedupReport({
    required this.newEvents,
    required this.duplicatesSkipped,
    required this.sourceTotal,
    required this.targetTotal,
  });

  final List<CalendarEvent> newEvents;
  final int duplicatesSkipped;
  final int sourceTotal;
  final int targetTotal;

  int get newCount => newEvents.length;
}
