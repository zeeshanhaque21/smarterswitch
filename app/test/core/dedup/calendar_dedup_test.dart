import 'package:flutter_test/flutter_test.dart';
import 'package:smarterswitch/core/dedup/calendar_dedup.dart';
import 'package:smarterswitch/core/model/calendar_event.dart';

CalendarEvent _evt({
  String? uid,
  required String title,
  String location = '',
  required int startUtcMs,
  required int endUtcMs,
  bool allDay = false,
}) =>
    CalendarEvent(
      uid: uid,
      title: title,
      location: location,
      startUtcMs: startUtcMs,
      endUtcMs: endUtcMs,
      allDay: allDay,
    );

void main() {
  group('CalendarDedup.keyFor — UID path', () {
    test('two events with the same UID match regardless of other fields', () {
      final a = _evt(
        uid: 'abc-123',
        title: 'Lunch',
        startUtcMs: 1700000000000,
        endUtcMs: 1700003600000,
      );
      final b = _evt(
        uid: 'abc-123',
        title: 'Different Title',
        startUtcMs: 9999999999999,
        endUtcMs: 9999999999999 + 3600000,
      );
      expect(CalendarDedup.keyFor(a), CalendarDedup.keyFor(b));
    });

    test('two events with different UIDs do NOT match even if everything else matches', () {
      final a = _evt(
        uid: 'abc-123',
        title: 'Lunch',
        startUtcMs: 1700000000000,
        endUtcMs: 1700003600000,
      );
      final b = _evt(
        uid: 'xyz-789',
        title: 'Lunch',
        startUtcMs: 1700000000000,
        endUtcMs: 1700003600000,
      );
      expect(
        CalendarDedup.keyFor(a),
        isNot(equals(CalendarDedup.keyFor(b))),
      );
    });
  });

  group('CalendarDedup.keyFor — composite path', () {
    test('UID-less events match on composite key', () {
      final a = _evt(
        title: 'Standup',
        startUtcMs: 1700000000000,
        endUtcMs: 1700001800000, // 30 min
      );
      final b = _evt(
        title: 'Standup',
        startUtcMs: 1700000000000,
        endUtcMs: 1700001800000,
      );
      expect(CalendarDedup.keyFor(a), CalendarDedup.keyFor(b));
    });

    test('case-insensitive title and location collapse', () {
      final a = _evt(
        title: 'Lunch with Alice',
        location: '101 Main St.',
        startUtcMs: 1700000000000,
        endUtcMs: 1700003600000,
      );
      final b = _evt(
        title: 'lunch with alice',
        location: '101 main st.',
        startUtcMs: 1700000000000,
        endUtcMs: 1700003600000,
      );
      expect(CalendarDedup.keyFor(a), CalendarDedup.keyFor(b));
    });

    test('different durations do NOT match', () {
      final shortMeeting = _evt(
        title: 'Sync',
        startUtcMs: 1700000000000,
        endUtcMs: 1700001800000, // 30 min
      );
      final longMeeting = _evt(
        title: 'Sync',
        startUtcMs: 1700000000000,
        endUtcMs: 1700003600000, // 60 min
      );
      expect(
        CalendarDedup.keyFor(shortMeeting),
        isNot(equals(CalendarDedup.keyFor(longMeeting))),
      );
    });

    test('all-day events stabilize duration to 24h', () {
      final source = _evt(
        title: 'Vacation',
        startUtcMs: 1700000000000,
        endUtcMs: 1700000000000 + 86400000, // 24h
        allDay: true,
      );
      final target = _evt(
        title: 'Vacation',
        startUtcMs: 1700000000000,
        // Some calendar providers report 24h - 1ms for all-day events.
        endUtcMs: 1700000000000 + 86399999,
        allDay: true,
      );
      expect(CalendarDedup.keyFor(source), CalendarDedup.keyFor(target));
    });
  });

  group('UID and composite are never equal', () {
    test('a UID-only key with the same string as a composite title doesn\'t collide', () {
      final uidEvent = _evt(
        uid: 'Standup',
        title: 'Standup',
        startUtcMs: 1700000000000,
        endUtcMs: 1700001800000,
      );
      final compositeEvent = _evt(
        title: 'Standup',
        startUtcMs: 1700000000000,
        endUtcMs: 1700001800000,
      );
      expect(
        CalendarDedup.keyFor(uidEvent),
        isNot(equals(CalendarDedup.keyFor(compositeEvent))),
      );
    });
  });

  group('CalendarDedup.diff', () {
    test('reports correctly on a mixed batch with both key kinds', () {
      final source = [
        _evt(
          uid: 'aaa-111',
          title: 'Sync',
          startUtcMs: 1700000000000,
          endUtcMs: 1700001800000,
        ),
        _evt(
          title: 'Local-only event',
          startUtcMs: 1700100000000,
          endUtcMs: 1700103600000,
        ),
        _evt(
          title: 'New event',
          startUtcMs: 1700200000000,
          endUtcMs: 1700203600000,
        ),
      ];
      final target = [
        // UID match on source[0].
        _evt(
          uid: 'aaa-111',
          title: 'Different cached title',
          startUtcMs: 9999999999999,
          endUtcMs: 9999999999999,
        ),
        // Composite match on source[1] with case difference.
        _evt(
          title: 'LOCAL-ONLY EVENT',
          startUtcMs: 1700100000000,
          endUtcMs: 1700103600000,
        ),
      ];
      final report = CalendarDedup.diff(source: source, target: target);
      expect(report.duplicatesSkipped, 2);
      expect(report.newCount, 1);
      expect(report.newEvents.single.title, 'New event');
    });
  });
}
