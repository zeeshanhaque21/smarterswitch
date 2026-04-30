import 'dart:async';
import 'dart:io';

import 'package:nsd/nsd.dart' as nsd;

import 'secure_socket_session.dart';
import 'transport.dart';

/// Same-LAN transport over mDNS + raw TCP.
///
/// Both phones must be on the same Wi-Fi network. The receiver advertises
/// itself as `_smarterswitch._tcp` and listens on a random TCP port; the
/// sender browses for the service, connects, and the two run a 6-digit-PIN
/// handshake before yielding a [PairedSession].
///
/// This is the simplest viable transport — no Wi-Fi Direct, no router-less
/// pairing, no full TLS yet. Sufficient for the v0.2 "prompt to connect"
/// UX. The Wi-Fi Direct transport (no shared network needed) and the
/// AES-GCM frame seal land in v0.3+.
class LanTransport implements Transport {
  LanTransport({this.serviceType = '_smarterswitch._tcp'});

  /// mDNS service type. Per RFC, must include the leading underscore.
  final String serviceType;

  ServerSocket? _server;
  nsd.Registration? _registration;
  nsd.Discovery? _discovery;

  // Receiver-only state.
  String? _expectedPin;
  Completer<PairedSession>? _acceptCompleter;
  StreamSubscription<Socket>? _serverSub;

  @override
  String get kind => 'Local Wi-Fi';

  @override
  TransportSpeedClass get speedClass => TransportSpeedClass.lan;

  @override
  Stream<DiscoveredPeer> discover() async* {
    final controller = StreamController<DiscoveredPeer>();
    final yieldedIds = <String>{};
    final discovery = await nsd.startDiscovery(serviceType);
    _discovery = discovery;

    Future<void> emitNew() async {
      for (final service in discovery.services) {
        nsd.Service resolved = service;
        if (resolved.host == null || resolved.port == null) {
          try {
            resolved = await nsd.resolve(service);
          } catch (_) {
            continue;
          }
        }
        final host = resolved.host;
        final port = resolved.port;
        if (host == null || port == null) continue;
        final id = '$host:$port';
        if (!yieldedIds.add(id)) continue;
        controller.add(DiscoveredPeer(
          id: id,
          displayName: resolved.name ?? 'Unknown',
          speedClass: TransportSpeedClass.lan,
        ));
      }
    }

    discovery.addListener(() {
      emitNew();
    });
    await emitNew();

    yield* controller.stream;
  }

  @override
  Future<void> advertise({required String displayName}) async {
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    final registration = await nsd.register(nsd.Service(
      name: displayName,
      type: serviceType,
      port: server.port,
    ));
    _registration = registration;
  }

  @override
  Future<void> stopAdvertising() async {
    final reg = _registration;
    if (reg != null) {
      try {
        await nsd.unregister(reg);
      } catch (_) {}
      _registration = null;
    }
  }

  @override
  Future<PairedSession> connect(
    DiscoveredPeer peer, {
    required String pin,
  }) async {
    final parts = peer.id.split(':');
    if (parts.length != 2) throw StateError('Bad peer id ${peer.id}');
    final host = parts[0];
    final port = int.parse(parts[1]);
    final socket = await Socket.connect(
      host,
      port,
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
    _expectedPin = pin;
    final completer = Completer<PairedSession>();
    _acceptCompleter = completer;

    _serverSub = server.listen((socket) async {
      try {
        final session = await SecureSocketSession.handshakeAsAcceptor(
          socket: socket,
          peerDisplayName: socket.remoteAddress.address,
          expectedPin: _expectedPin!,
        );
        if (!completer.isCompleted) completer.complete(session);
      } catch (_) {
        // PIN mismatch / IO error — already handled by the helper. Drop
        // this socket; another sender may still try with the right PIN.
      }
    });

    return completer.future;
  }

  @override
  Future<void> close() async {
    await _serverSub?.cancel();
    _serverSub = null;
    await stopAdvertising();
    final disc = _discovery;
    if (disc != null) {
      try {
        await nsd.stopDiscovery(disc);
      } catch (_) {}
      _discovery = null;
    }
    final s = _server;
    if (s != null) {
      try {
        await s.close();
      } catch (_) {}
      _server = null;
    }
    if (_acceptCompleter != null && !_acceptCompleter!.isCompleted) {
      _acceptCompleter!.completeError(StateError('Transport closed'));
    }
  }
}

