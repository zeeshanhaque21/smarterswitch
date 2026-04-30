import 'package:flutter/services.dart';

import '../core/model/calendar_event.dart';

/// Dart wrapper for `smarterswitch/calendar` — read + count + write.
class CalendarReader {
  CalendarReader({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('smarterswitch/calendar');
  final MethodChannel _channel;

  Future<bool> hasReadPermission() async =>
      (await _channel.invokeMethod<bool>('hasReadPermission')) ?? false;

  Future<bool> hasWritePermission() async =>
      (await _channel.invokeMethod<bool>('hasWritePermission')) ?? false;

  Future<int> count() async =>
      (await _channel.invokeMethod<num>('count'))?.toInt() ?? 0;

  Future<List<CalendarEvent>> readAll() async {
    final raw = await _channel.invokeMethod<List<Object?>>('readAll');
    if (raw == null) return const [];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map(_fromMap)
        .toList(growable: false);
  }

  Future<int> writeAll(List<CalendarEvent> events) async {
    final args = events.map(_toMap).toList(growable: false);
    final n = await _channel.invokeMethod<num>('writeAll', args);
    return n?.toInt() ?? 0;
  }

  static CalendarEvent _fromMap(Map<Object?, Object?> m) => CalendarEvent(
        uid: m['uid'] as String?,
        title: (m['title'] as String?) ?? '',
        location: (m['location'] as String?) ?? '',
        startUtcMs: (m['startUtcMs'] as num?)?.toInt() ?? 0,
        endUtcMs: (m['endUtcMs'] as num?)?.toInt() ?? 0,
        allDay: m['allDay'] as bool? ?? false,
        recurrence: m['recurrence'] as String?,
      );

  static Map<String, Object?> _toMap(CalendarEvent e) => {
        'uid': e.uid,
        'title': e.title,
        'location': e.location,
        'startUtcMs': e.startUtcMs,
        'endUtcMs': e.endUtcMs,
        'allDay': e.allDay,
        'recurrence': e.recurrence,
        // 'duration' is left unset; the writer falls back to DTEND-based.
      };
}
