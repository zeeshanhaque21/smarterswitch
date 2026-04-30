import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nsd/nsd.dart' as nsd;

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
        // Some platforms return services already-resolved (host/port set);
        // others return only name+type and require an explicit resolve.
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
      // Fire-and-forget; emitNew handles its own errors.
      emitNew();
    });
    await emitNew();

    yield* controller.stream;
  }

  @override
  Future<void> advertise({required String displayName}) async {
    // Start the listener now so we already have a port to advertise.
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
    final socket = await Socket.connect(host, port,
        timeout: const Duration(seconds: 10));
    // Sender protocol: send PIN line, await OK.
    socket.write('PIN $pin\n');
    await socket.flush();
    final replyBytes = await _readLine(socket);
    final reply = utf8.decode(replyBytes).trim();
    if (reply == 'OK') {
      return _LanSession(
        peerDisplayName: peer.displayName,
        socket: socket,
      );
    }
    socket.destroy();
    throw const PinMismatchException();
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
        final line = await _readLine(socket);
        final received = utf8.decode(line).trim();
        if (received.startsWith('PIN ') &&
            received.substring(4) == _expectedPin) {
          socket.write('OK\n');
          await socket.flush();
          if (!completer.isCompleted) {
            completer.complete(_LanSession(
              peerDisplayName:
                  socket.remoteAddress.address, // upgraded by app layer later
              socket: socket,
            ));
          }
        } else {
          socket.write('BAD\n');
          await socket.flush();
          socket.destroy();
        }
      } catch (e) {
        socket.destroy();
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

  /// Read bytes until `\n`. Returns the bytes excluding the newline.
  static Future<Uint8List> _readLine(Socket socket) async {
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in socket) {
      for (final byte in chunk) {
        if (byte == 0x0a) {
          return buffer.toBytes();
        }
        buffer.addByte(byte);
      }
    }
    return buffer.toBytes();
  }
}

class _LanSession implements PairedSession {
  _LanSession({required this.peerDisplayName, required Socket socket})
      : _socket = socket {
    _socket.listen(
      (data) {
        // Buffer raw bytes; framed-decode happens at a higher layer once
        // FrameCodec is plugged in.
        _incoming.add(Uint8List.fromList(data));
      },
      onDone: () => _incoming.close(),
      onError: (_) => _incoming.close(),
    );
  }

  @override
  final String peerDisplayName;

  final Socket _socket;
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast();

  @override
  Future<void> sendFrame(Uint8List frame) async {
    _socket.add(frame);
    await _socket.flush();
  }

  @override
  Stream<Uint8List> incomingFrames() => _incoming.stream;

  @override
  String get resumeToken => '';

  @override
  Future<void> close() async {
    await _socket.close();
    if (!_incoming.isClosed) await _incoming.close();
  }
}
