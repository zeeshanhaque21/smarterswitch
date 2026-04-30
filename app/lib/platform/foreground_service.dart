import 'package:flutter/services.dart';

/// Wrapper around the `smarterswitch/foreground` MethodChannel. The actual
/// service body is in `TransferForegroundService.kt`; this just toggles it
/// on/off from Dart-side lifecycle events.
class ForegroundService {
  ForegroundService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('smarterswitch/foreground');
  final MethodChannel _channel;

  Future<void> start() async {
    try {
      await _channel.invokeMethod<bool>('start');
    } catch (_) {
      // Foreground services can fail to start under aggressive OEM battery
      // policies (Xiaomi, Huawei) — surface as a no-op rather than tank
      // the transfer. The platform side has already logged the failure.
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod<bool>('stop');
    } catch (_) {}
  }
}
