import 'dart:convert';
import 'dart:io';

import '../model/calendar_event.dart';
import '../model/call_log_record.dart';
import '../model/contact.dart';
import '../model/media_record.dart';

/// JSON readers for category records, used by the CLI dedup harnesses
/// (`tool/dedup_diff.dart`). The shape is the obvious flat translation of
/// each model class — nothing fancy, intentionally easy for users to hand-
/// edit when assembling a validation set.
class CategoryJson {
  static List<CallLogRecord> readCallLog(File f) {
    final raw = jsonDecode(f.readAsStringSync()) as List<dynamic>;
    return raw
        .cast<Map<String, dynamic>>()
        .map((m) => CallLogRecord(
              number: m['number'] as String,
              timestampMs: (m['timestampMs'] as num).toInt(),
              durationSeconds: (m['durationSeconds'] as num).toInt(),
              direction: _callDirectionFromString(m['direction'] as String),
              cachedName: m['cachedName'] as String?,
            ))
        .toList(growable: false);
  }

  static List<CalendarEvent> readCalendar(File f) {
    final raw = jsonDecode(f.readAsStringSync()) as List<dynamic>;
    return raw.cast<Map<String, dynamic>>().map((m) {
      return CalendarEvent(
        uid: m['uid'] as String?,
        title: m['title'] as String? ?? '',
        location: m['location'] as String? ?? '',
        startUtcMs: (m['startUtcMs'] as num).toInt(),
        endUtcMs: (m['endUtcMs'] as num).toInt(),
        allDay: m['allDay'] as bool? ?? false,
        recurrence: m['recurrence'] as String?,
      );
    }).toList(growable: false);
  }

  static List<Contact> readContacts(File f) {
    final raw = jsonDecode(f.readAsStringSync()) as List<dynamic>;
    return raw.cast<Map<String, dynamic>>().map((m) {
      return Contact(
        sourceAccountType: m['sourceAccountType'] as String?,
        displayName: m['displayName'] as String? ?? '',
        givenName: m['givenName'] as String?,
        familyName: m['familyName'] as String?,
        phones: ((m['phones'] as List<dynamic>?) ?? const [])
            .cast<String>()
            .toList(growable: false),
        emails: ((m['emails'] as List<dynamic>?) ?? const [])
            .cast<String>()
            .toList(growable: false),
        organization: m['organization'] as String?,
      );
    }).toList(growable: false);
  }

  static List<MediaRecord> readMedia(File f) {
    final raw = jsonDecode(f.readAsStringSync()) as List<dynamic>;
    return raw.cast<Map<String, dynamic>>().map((m) {
      return MediaRecord(
        uri: m['uri'] as String,
        fileName: m['fileName'] as String,
        byteSize: (m['byteSize'] as num).toInt(),
        kind: (m['kind'] as String) == 'video'
            ? MediaKind.video
            : MediaKind.image,
        sha256Hex: m['sha256Hex'] as String,
        pHash: (m['pHash'] as num?)?.toInt(),
        takenAtMs: (m['takenAtMs'] as num?)?.toInt(),
      );
    }).toList(growable: false);
  }

  static CallDirection _callDirectionFromString(String s) {
    switch (s) {
      case 'incoming':
        return CallDirection.incoming;
      case 'outgoing':
        return CallDirection.outgoing;
      case 'missed':
        return CallDirection.missed;
      case 'rejected':
        return CallDirection.rejected;
      default:
        throw FormatException('Unknown call direction: $s');
    }
  }
}
