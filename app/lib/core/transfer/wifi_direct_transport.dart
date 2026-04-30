import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'secure_socket_session.dart';
import 'transport.dart';

/// Wi-Fi Direct transport — peer-to-peer over the Android `WifiP2pManager`
/// stack. No shared Wi-Fi router required.
///
/// Flow:
/// - Receiver: `enable()` → `advertise()` (kicks off discovery + listens
///   for inbound `accept` after a peer initiates connect) → `accept(pin)`.
///   Receiver pins `groupOwnerIntent=15` so it deterministically becomes
///   the GO and runs the TCP listener at the framework-assigned
///   `192.168.49.1`.
/// - Sender: `enable()` → `discover()` (yields peers as they appear) →
///   `connect(peer, pin)` triggers group formation + TCP connect to GO.
///
/// Once a TCP socket exists, both sides hand off to `SecureSocketSession`
/// for the PIN/X25519 handshake + AES-GCM-sealed framed traffic — same
/// protocol as `LanTransport`.
class WifiDirectTransport implements Transport {
  WifiDirectTransport({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('smarterswitch/wifi_direct');

  final MethodChannel _channel;

  /// Fixed port the receiver's TCP server binds to. Sender connects here
  /// once group formation is complete.
  static const int _tcpPort = 47625;

  /// Group owner address pinned by the framework when groupOwnerIntent=15.
  static const String _groupOwnerHost = '192.168.49.1';

  ServerSocket? _server;
  Completer<PairedSession>? _acceptCompleter;
  StreamSubscription<Socket>? _serverSub;

  static Future<bool> isAvailable({MethodChannel? channel}) async {
    final c = channel ?? const MethodChannel('smarterswitch/wifi_direct');
    try {
      return (await c.invokeMethod<bool>('isAvailable')) ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  String get kind => 'Wi-Fi Direct';

  @override
  TransportSpeedClass get speedClass => TransportSpeedClass.wifiDirect;

  Future<void> enable() async {
    await _channel.invokeMethod<bool>('enable');
  }

  Future<void> _disable() async {
    try {
      await _channel.invokeMethod<bool>('disable');
    } catch (_) {}
  }

  Future<void> _removeGroup() async {
    try {
      await _channel.invokeMethod<bool>('removeGroup');
    } catch (_) {}
  }

  @override
  Stream<DiscoveredPeer> discover() async* {
    await enable();
    final yielded = <String>{};
    while (true) {
      try {
        await _channel.invokeMethod<bool>('discoverPeers');
      } catch (_) {/* try again next loop */}
      // Pull whatever the BroadcastReceiver has cached. The PEERS_CHANGED
      // intent updates the cache asynchronously; we poll every 2s.
      final raw = (await _channel.invokeMethod<List<Object?>>('getPeers')) ?? const [];
      for (final entry in raw.whereType<Map<Object?, Object?>>()) {
        final id = (entry['deviceAddress'] as String?) ?? '';
        if (id.isEmpty) continue;
        if (!yielded.add(id)) continue;
        yield DiscoveredPeer(
          id: id,
          displayName: (entry['deviceName'] as String?) ?? id,
          speedClass: TransportSpeedClass.wifiDirect,
        );
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  @override
  Future<void> advertise({required String displayName}) async {
    // Wi-Fi Direct doesn't have an "advertise" call — the receiver just
    // needs to be discoverable. enable() kicks the BroadcastReceiver and
    // initialize() registers the device with the framework. The sender's
    // discoverPeers will surface us.
    await enable();
    // Also kick a discovery on our side so we appear in the framework's
    // peer table on the sender's device. Some OEMs only register us once
    // we've initiated a discovery scan ourselves.
    try {
      await _channel.invokeMethod<bool>('discoverPeers');
    } catch (_) {}
    // Bind the TCP listener now so the GO address (192.168.49.1) is
    // ready as soon as group formation completes.
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, _tcpPort);
    _server = server;
  }

  @override
  Future<void> stopAdvertising() async {
    final s = _server;
    _server = null;
    if (s != null) {
      try {
        await s.close();
      } catch (_) {}
    }
  }

  @override
  Future<PairedSession> connect(
    DiscoveredPeer peer, {
    required String pin,
  }) async {
    await enable();
    // Trigger group formation. Sender pins groupOwnerIntent=0 so the peer
    // (which we've directed to use 15) deterministically wins GO election.
    try {
      await _channel.invokeMethod<bool>('connect', {
        'deviceAddress': peer.id,
        'isReceiver': false,
      });
    } on PlatformException catch (e) {
      throw StateError('Wi-Fi Direct connect failed: ${e.message}');
    }
    // Wait for the group to form. Poll every 500ms up to 30s.
    final formed = await _awaitGroupFormation(timeout: const Duration(seconds: 30));
    if (!formed) {
      await _removeGroup();
      throw StateError('Wi-Fi Direct group did not form in time');
    }
    final socket = await Socket.connect(
      _groupOwnerHost,
      _tcpPort,
      timeout: const Duration(seconds: 10),
    );
    return SecureSocketSession.handshakeAsConnector(
      socket: socket,
      peerDisplayName: peer.displayName,
      pin: pin,
    );
  }

  @override
  Future<PairedSession> accept({required String pin}) async {
    final server = _server;
    if (server == null) {
      throw StateError('advertise() must be called before accept()');
    }
    final completer = Completer<PairedSession>();
    _acceptCompleter = completer;

    _serverSub = server.listen((socket) async {
      try {
        final session = await SecureSocketSession.handshakeAsAcceptor(
          socket: socket,
          peerDisplayName: socket.remoteAddress.address,
          expectedPin: pin,
        );
        if (!completer.isCompleted) completer.complete(session);
      } catch (_) {
        // PIN mismatch / IO error — drop this socket; let next attempt try.
      }
    });

    return completer.future;
  }

  Future<bool> _awaitGroupFormation({required Duration timeout}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final info =
            await _channel.invokeMethod<Map<Object?, Object?>>('getConnectionInfo');
        if (info != null && info['connected'] == true) return true;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }

  @override
  Future<void> close() async {
    await _serverSub?.cancel();
    _serverSub = null;
    await stopAdvertising();
    await _removeGroup();
    await _disable();
    if (_acceptCompleter != null && !_acceptCompleter!.isCompleted) {
      _acceptCompleter!.completeError(StateError('Transport closed'));
    }
  }
}
