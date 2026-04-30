import 'package:flutter/services.dart';

import '../core/model/call_log_record.dart';

/// Dart wrapper for the `smarterswitch/calllog` channel — full read + write.
class CallLogReader {
  CallLogReader({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('smarterswitch/calllog');

  final MethodChannel _channel;

  Future<bool> hasReadPermission() async =>
      (await _channel.invokeMethod<bool>('hasReadPermission')) ?? false;

  Future<bool> hasWritePermission() async =>
      (await _channel.invokeMethod<bool>('hasWritePermission')) ?? false;

  Future<int> count() async =>
      (await _channel.invokeMethod<num>('count'))?.toInt() ?? 0;

  Future<List<CallLogRecord>> readAll() async {
    final raw = await _channel.invokeMethod<List<Object?>>('readAll');
    if (raw == null) return const [];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map(_recordFromMap)
        .toList(growable: false);
  }

  /// Returns the count of records the OS accepted (some rows may be rejected
  /// for content-provider-specific reasons; we report the real number written).
  Future<int> writeAll(List<CallLogRecord> records) async {
    final args = records.map(_recordToMap).toList(growable: false);
    final n = await _channel.invokeMethod<num>('writeAll', args);
    return n?.toInt() ?? 0;
  }

  static CallLogRecord _recordFromMap(Map<Object?, Object?> m) {
    return CallLogRecord(
      number: (m['number'] as String?) ?? '',
      timestampMs: (m['timestampMs'] as num?)?.toInt() ?? 0,
      durationSeconds: (m['durationSeconds'] as num?)?.toInt() ?? 0,
      direction: _directionFromAndroidInt((m['type'] as num?)?.toInt() ?? 1),
      cachedName: m['cachedName'] as String?,
    );
  }

  static Map<String, Object?> _recordToMap(CallLogRecord r) => {
        'number': r.number,
        'timestampMs': r.timestampMs,
        'durationSeconds': r.durationSeconds,
        'type': _directionToAndroidInt(r.direction),
        'cachedName': r.cachedName,
      };

  /// AOSP `CallLog.Calls.TYPE` constants:
  /// 1 INCOMING, 2 OUTGOING, 3 MISSED, 4 VOICEMAIL, 5 REJECTED, 6 BLOCKED.
  static CallDirection _directionFromAndroidInt(int v) {
    switch (v) {
      case 2:
        return CallDirection.outgoing;
      case 3:
        return CallDirection.missed;
      case 5:
      case 6:
        return CallDirection.rejected;
      default:
        return CallDirection.incoming;
    }
  }

  static int _directionToAndroidInt(CallDirection d) {
    switch (d) {
      case CallDirection.incoming:
        return 1;
      case CallDirection.outgoing:
        return 2;
      case CallDirection.missed:
        return 3;
      case CallDirection.rejected:
        return 5;
    }
  }
}
