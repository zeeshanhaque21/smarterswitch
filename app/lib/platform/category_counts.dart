import 'package:permission_handler/permission_handler.dart';

import '../state/transfer_state.dart';
import 'calendar_reader.dart';
import 'call_log_reader.dart';
import 'category_channels.dart';
import 'contacts_reader.dart';
import 'sms_reader.dart';

/// Probes counts and permission state for all five data categories in
/// parallel. The Select screen calls this once on mount and then again after
/// the user grants any new permission. Latency budget: sub-second on a
/// 30k-photo device — the underlying queries are all `SELECT COUNT(*)` over
/// content providers.
class CategoryProbe {
  CategoryProbe({
    SmsReader? sms,
    CallLogReader? callLog,
    ContactsReader? contacts,
    CalendarReader? calendar,
    MediaReader? media,
  })  : _sms = sms ?? SmsReader(),
        _callLog = callLog ?? CallLogReader(),
        _contacts = contacts ?? ContactsReader(),
        _calendar = calendar ?? CalendarReader(),
        _media = media ?? MediaReader();

  final SmsReader _sms;
  final CallLogReader _callLog;
  final ContactsReader _contacts;
  final CalendarReader _calendar;
  final MediaReader _media;

  Future<Map<DataCategory, CategoryStatus>> probeAll() async {
    final results = await Future.wait([
      _probeSms(),
      _probeCallLog(),
      _probeContacts(),
      _probeCalendar(),
      _probeMedia(),
    ]);
    return {for (final s in results) s.category: s};
  }

  Future<CategoryStatus> _probeSms() => _probeCounting(
        category: DataCategory.sms,
        hasPermission: _sms.hasReadPermission,
        count: _sms.count,
      );

  Future<CategoryStatus> _probeCallLog() => _probeCounting(
        category: DataCategory.callLog,
        hasPermission: _callLog.hasReadPermission,
        count: _callLog.count,
      );

  Future<CategoryStatus> _probeContacts() => _probeCounting(
        category: DataCategory.contacts,
        hasPermission: _contacts.hasReadPermission,
        count: _contacts.count,
      );

  Future<CategoryStatus> _probeCalendar() => _probeCounting(
        category: DataCategory.calendar,
        hasPermission: _calendar.hasReadPermission,
        count: _calendar.count,
      );

  Future<CategoryStatus> _probeMedia() async {
    final granted = await _safeBool(_media.hasReadPermission);
    if (!granted) {
      return const CategoryStatus(
        category: DataCategory.photos,
        permissionState: PermissionState.denied,
      );
    }
    try {
      final s = await _media.summary();
      return CategoryStatus(
        category: DataCategory.photos,
        permissionState: PermissionState.granted,
        count: s.count,
        estimatedBytes: s.totalBytes,
      );
    } catch (_) {
      return const CategoryStatus(
        category: DataCategory.photos,
        permissionState: PermissionState.granted,
      );
    }
  }

  Future<CategoryStatus> _probeCounting({
    required DataCategory category,
    required Future<bool> Function() hasPermission,
    required Future<int> Function() count,
  }) async {
    final granted = await _safeBool(hasPermission);
    if (!granted) {
      return CategoryStatus(
        category: category,
        permissionState: PermissionState.denied,
      );
    }
    try {
      final n = await count();
      return CategoryStatus(
        category: category,
        permissionState: PermissionState.granted,
        count: n,
      );
    } catch (_) {
      return CategoryStatus(
        category: category,
        permissionState: PermissionState.granted,
      );
    }
  }

  Future<bool> _safeBool(Future<bool> Function() f) async {
    try {
      return await f();
    } catch (_) {
      return false;
    }
  }
}

/// Maps each [DataCategory] to the runtime permission(s) it needs. Used by
/// the Select screen's "Tap to allow" inline CTA.
List<Permission> permissionsFor(DataCategory category) {
  switch (category) {
    case DataCategory.sms:
      return [Permission.sms];
    case DataCategory.callLog:
      return [Permission.phone];
    case DataCategory.contacts:
      return [Permission.contacts];
    case DataCategory.calendar:
      return [Permission.calendarFullAccess];
    case DataCategory.photos:
      // Permission.photos covers the API-33+ READ_MEDIA_IMAGES split;
      // Permission.videos covers READ_MEDIA_VIDEO. permission_handler
      // transparently maps to READ_EXTERNAL_STORAGE on API ≤ 32.
      return [Permission.photos, Permission.videos];
  }
}
