import 'dart:async';

import 'package:permission_handler/permission_handler.dart';

import '../state/transfer_state.dart';
import 'calendar_reader.dart';
import 'call_log_reader.dart';
import 'contacts_reader.dart';
import 'media_reader.dart';
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

  /// Streaming variant — emits each [CategoryStatus] as soon as that
  /// category's probe completes, so the UI can fill in fast results
  /// immediately. Only categories in [kEnabledCategories] are probed;
  /// disabled ones never run their permission/count platform calls,
  /// which sidesteps the slow MediaStore summary, the photos
  /// permission flow, and any other still-flaky probe paths.
  Stream<CategoryStatus> probeStream() async* {
    final controller = StreamController<CategoryStatus>();
    final probes = <Future<CategoryStatus>>[
      if (kEnabledCategories.contains(DataCategory.sms)) _probeSms(),
      if (kEnabledCategories.contains(DataCategory.callLog)) _probeCallLog(),
      if (kEnabledCategories.contains(DataCategory.contacts)) _probeContacts(),
      if (kEnabledCategories.contains(DataCategory.calendar)) _probeCalendar(),
      if (kEnabledCategories.contains(DataCategory.photos)) _probeMedia(),
    ];
    if (probes.isEmpty) {
      // Defensive: if every category is disabled (a config bug), close
      // the stream immediately rather than hanging forever.
      controller.close();
      yield* controller.stream;
      return;
    }
    var pending = probes.length;
    void onResult(CategoryStatus s) {
      controller.add(s);
      if (--pending == 0) controller.close();
    }
    for (final p in probes) {
      p.then(onResult);
    }
    yield* controller.stream;
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
    // summary() iterates the full MediaStore cursor to sum file sizes
    // for the byte-estimate; on a 30k-photo library that's seconds, on
    // pathological cases (slow SD card, lots of cloud-stub stale rows)
    // it can be much longer. Time-box to 8 seconds; if it doesn't return
    // we fall back to count-only and let the UI display the count
    // without the size estimate. The user can still proceed.
    try {
      final s = await _media.summary().timeout(const Duration(seconds: 8));
      return CategoryStatus(
        category: DataCategory.photos,
        permissionState: PermissionState.granted,
        count: s.count,
        estimatedBytes: s.totalBytes,
      );
    } on TimeoutException {
      try {
        final n = await _media.count().timeout(const Duration(seconds: 4));
        return CategoryStatus(
          category: DataCategory.photos,
          permissionState: PermissionState.granted,
          count: n,
        );
      } catch (_) {
        return const CategoryStatus(
          category: DataCategory.photos,
          permissionState: PermissionState.granted,
        );
      }
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
    // 5-second timeout on each step. A platform channel that never
    // returns (rare but real on some OEMs) used to leave the row's
    // spinner spinning forever; v0.15.1 forces a worst-case 10s before
    // every category surfaces SOMETHING (count, denied, or the
    // unknown-state fallback).
    final granted =
        await _safeBool(hasPermission, timeout: const Duration(seconds: 5));
    if (!granted) {
      return CategoryStatus(
        category: category,
        permissionState: PermissionState.denied,
      );
    }
    try {
      final n = await count().timeout(const Duration(seconds: 5));
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

  Future<bool> _safeBool(
    Future<bool> Function() f, {
    Duration? timeout,
  }) async {
    try {
      final fut = f();
      return await (timeout == null ? fut : fut.timeout(timeout));
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
