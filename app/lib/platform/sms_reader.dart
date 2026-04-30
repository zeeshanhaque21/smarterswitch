import 'package:flutter/services.dart';

import '../core/model/sms_record.dart';

/// Dart-side wrapper around the `smarterswitch/sms` `MethodChannel`. The
/// platform implementation lives in `android/.../native/SmsChannel.kt` (Android)
/// and is intentionally absent on iOS, where the OS does not expose SMS to
/// third-party apps — see ARCHITECTURE.md § Platform constraints.
class SmsReader {
  SmsReader({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('smarterswitch/sms');

  final MethodChannel _channel;

  Future<bool> hasReadPermission() async {
    final granted = await _channel.invokeMethod<bool>('hasReadPermission');
    return granted ?? false;
  }

  /// Cheap row count — `SELECT COUNT(*)` on the platform side, no row read.
  /// Used by the Select screen so the count is visible before any heavy work
  /// happens.
  Future<int> count() async =>
      (await _channel.invokeMethod<num>('count'))?.toInt() ?? 0;

  /// Read every SMS row from the device. The platform side performs the cursor
  /// read off the main thread; on a 5k-message device this is well under a
  /// second on modern hardware.
  Future<List<SmsRecord>> readAll() async {
    final raw = await _channel.invokeMethod<List<Object?>>('readAll');
    if (raw == null) return const [];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map(_recordFromMap)
        .toList(growable: false);
  }

  Future<bool> isDefaultSmsApp() async =>
      (await _channel.invokeMethod<bool>('isDefaultSmsApp')) ?? false;

  /// Package name of whatever app is currently default — surfaced so the
  /// Done screen can tell the user which app to open to switch back.
  Future<String?> getDefaultSmsPackage() async =>
      _channel.invokeMethod<String>('getDefaultSmsPackage');

  /// Pop the system "Set as default SMS app" dialog. Resolves true if the
  /// user accepted; false if denied or the role isn't available on this
  /// device. Must be called from a UI thread.
  Future<bool> requestSmsRole() async =>
      (await _channel.invokeMethod<bool>('requestSmsRole')) ?? false;

  /// Bulk-insert SMS records. Only legal while the app is the default SMS
  /// handler — call after [requestSmsRole] returns true. Returns the count
  /// the OS accepted; some rows may be rejected by content-provider rules
  /// and that's reflected in the count.
  Future<int> writeAll(List<SmsRecord> records) async {
    final args = records.map(_recordToMap).toList(growable: false);
    final n = await _channel.invokeMethod<num>('writeAll', args);
    return n?.toInt() ?? 0;
  }

  static Map<String, Object?> _recordToMap(SmsRecord r) => {
        'address': r.address,
        'body': r.body,
        'timestampMs': r.timestampMs,
        'type': _typeToAndroidInt(r.type),
      };

  static int _typeToAndroidInt(SmsType t) {
    switch (t) {
      case SmsType.inbox:
        return 1;
      case SmsType.sent:
        return 2;
      case SmsType.draft:
        return 3;
      case SmsType.outbox:
        return 4;
      case SmsType.failed:
        return 5;
      case SmsType.queued:
        return 6;
    }
  }

  static SmsRecord _recordFromMap(Map<Object?, Object?> map) {
    return SmsRecord(
      address: (map['address'] as String?) ?? '',
      body: (map['body'] as String?) ?? '',
      timestampMs: (map['timestampMs'] as num?)?.toInt() ?? 0,
      type: _typeFromAndroidInt((map['type'] as num?)?.toInt() ?? 0),
      threadId: (map['threadId'] as num?)?.toInt(),
    );
  }

  /// Map the Android `Telephony.Sms.MESSAGE_TYPE_*` constants to our enum.
  /// The numeric values come from the AOSP SmsContract (1 = inbox, 2 = sent,
  /// 3 = draft, 4 = outbox, 5 = failed, 6 = queued).
  static SmsType _typeFromAndroidInt(int v) {
    switch (v) {
      case 1:
        return SmsType.inbox;
      case 2:
        return SmsType.sent;
      case 3:
        return SmsType.draft;
      case 4:
        return SmsType.outbox;
      case 5:
        return SmsType.failed;
      case 6:
        return SmsType.queued;
      default:
        return SmsType.inbox;
    }
  }
}
