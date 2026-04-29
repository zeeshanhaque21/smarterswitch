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
