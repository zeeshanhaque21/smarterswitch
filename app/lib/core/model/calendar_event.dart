/// Single calendar event, normalized into a platform-agnostic form before
/// being fed to the calendar dedup engine.
class CalendarEvent {
  const CalendarEvent({
    required this.startUtcMs,
    required this.endUtcMs,
    required this.title,
    this.uid,
    this.location = '',
    this.allDay = false,
    this.recurrence,
  });

  /// CalDAV/iCal UID. When present (CalDAV-imported events almost always have
  /// one), this alone is the dedup key — UIDs are universally unique by spec.
  /// When absent (locally-created events), we fall back to a composite key.
  final String? uid;

  final int startUtcMs;
  final int endUtcMs;

  final String title;
  final String location;

  final bool allDay;

  /// Source-reported RRULE-style string. Carried through but not used in
  /// matching — different calendar providers serialize the same recurrence
  /// rule differently.
  final String? recurrence;

  /// Duration in milliseconds, used by the composite-key path. All-day events
  /// always report 24h duration regardless of source-side end time, so this
  /// stays stable across providers.
  int get durationMs {
    if (allDay) return 24 * 60 * 60 * 1000;
    return endUtcMs - startUtcMs;
  }
}
