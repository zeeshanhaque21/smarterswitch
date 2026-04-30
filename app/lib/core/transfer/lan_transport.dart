import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:nsd/nsd.dart' as nsd;

import 'handshake.dart';
import 'transport.dart';
import 'wire/frame_codec.dart';

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
    // Hand the socket to the session immediately — the session owns the only
    // listener from this point on. Mixing `socket.listen` with `await for`
    // throws "Stream already listened to" because Socket is single-sub.
    final session = _LanSession(
      peerDisplayName: peer.displayName,
      socket: socket,
    );
    socket.write('PIN $pin\n');
    await socket.flush();
    final reply = (await session._readHandshakeLine()).trim();
    if (reply == 'OK') {
      await session._performKeyExchange(pin);
      session._handshakeDone();
      return session;
    }
    await session.close();
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
      // Same single-listener invariant as connect(): the session is built
      // first; the session's listener consumes the handshake line and then
      // forwards subsequent bytes.
      final session = _LanSession(
        peerDisplayName: socket.remoteAddress.address,
        socket: socket,
      );
      try {
        final received = (await session._readHandshakeLine()).trim();
        if (received.startsWith('PIN ') &&
            received.substring(4) == _expectedPin) {
          socket.write('OK\n');
          await socket.flush();
          await session._performKeyExchange(_expectedPin!);
          session._handshakeDone();
          if (!completer.isCompleted) completer.complete(session);
        } else {
          socket.write('BAD\n');
          await socket.flush();
          await session.close();
        }
      } catch (e) {
        await session.close();
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

/// Session backed by a TCP socket. The session owns the *only* listener on
/// the socket. During the handshake phase, incoming bytes accumulate in a
/// line buffer and are consumed by [_readHandshakeLine]. After
/// [_handshakeDone] is called, subsequent bytes are forwarded to
/// [incomingFrames].
class _LanSession implements PairedSession {
  _LanSession({required this.peerDisplayName, required Socket socket})
      : _socket = socket {
    _subscription = socket.listen(
      _onData,
      onDone: () {
        if (!_incoming.isClosed) _incoming.close();
      },
      onError: (Object e) {
        if (!_incoming.isClosed) _incoming.close();
      },
    );
  }

  @override
  final String peerDisplayName;

  final Socket _socket;
  late final StreamSubscription<Uint8List> _subscription;

  bool _handshakeFinished = false;
  final BytesBuilder _handshakeBuffer = BytesBuilder(copy: false);
  Completer<String>? _readLineCompleter;
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast();

  /// 32-byte symmetric key derived during the post-PIN X25519 exchange.
  /// All framed messages after handshake are sealed with AES-GCM under
  /// this key. Wrong PIN ⇒ different key on the two sides ⇒ MAC fails ⇒
  /// frames silently drop on the receiver.
  Uint8List? _sessionKey;
  static final _aes = AesGcm.with256bits();

  Future<String> _readHandshakeLine() {
    final c = Completer<String>();
    _readLineCompleter = c;
    return c.future;
  }

  /// Post-PIN X25519 + HKDF exchange. Each side generates a fresh keypair,
  /// sends its public key as a `PUBKEY <base64>\n` text line, reads the
  /// peer's, and derives a shared 32-byte key with the user's PIN as the
  /// HKDF salt. Wrong PIN ⇒ different keys on the two sides ⇒ AES-GCM
  /// auth fails on the first sealed frame.
  Future<void> _performKeyExchange(String pin) async {
    final keyPair = await Handshake.generate();
    _socket.write('PUBKEY ${base64.encode(keyPair.publicKeyBytes)}\n');
    await _socket.flush();
    final line = (await _readHandshakeLine()).trim();
    if (!line.startsWith('PUBKEY ')) {
      throw StateError('Expected PUBKEY, got "$line"');
    }
    final peerPub = base64.decode(line.substring('PUBKEY '.length));
    _sessionKey = await Handshake.deriveSharedKey(
      myKeyPair: keyPair,
      peerPublicKey: peerPub,
      pin: pin,
    );
  }

  Future<Uint8List> _seal(Uint8List plaintext, Uint8List key) async {
    final box = await _aes.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: _aes.newNonce(),
    );
    final out = BytesBuilder()
      ..add(box.nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.toBytes();
  }

  Future<Uint8List> _unseal(Uint8List sealed, Uint8List key) async {
    if (sealed.length < 28) {
      throw StateError('Sealed frame too short');
    }
    final nonce = sealed.sublist(0, 12);
    final mac = sealed.sublist(sealed.length - 16);
    final cipher = sealed.sublist(12, sealed.length - 16);
    final box = SecretBox(cipher, nonce: nonce, mac: Mac(mac));
    final plaintext = await _aes.decrypt(box, secretKey: SecretKey(key));
    return Uint8List.fromList(plaintext);
  }

  void _handshakeDone() {
    _handshakeFinished = true;
    // Anything still in the buffer (rare — but a peer can pipeline) goes to
    // incoming as the first frame so post-handshake reads don't lose data.
    if (_handshakeBuffer.length > 0) {
      _incoming.add(_handshakeBuffer.toBytes());
      _handshakeBuffer.clear();
    }
  }

  void _onData(Uint8List data) {
    if (_handshakeFinished) {
      _incoming.add(data);
      return;
    }
    // Still in handshake: scan for the first newline; up to it is the line,
    // anything after it stays buffered for later (typically nothing).
    for (var i = 0; i < data.length; i++) {
      final byte = data[i];
      if (byte == 0x0a) {
        final line = utf8.decode(_handshakeBuffer.toBytes());
        _handshakeBuffer.clear();
        // Keep any bytes after the newline; they'll either feed another
        // handshake line (unlikely) or be flushed to incoming when
        // _handshakeDone is called.
        if (i + 1 < data.length) {
          _handshakeBuffer.add(data.sublist(i + 1));
        }
        final c = _readLineCompleter;
        _readLineCompleter = null;
        c?.complete(line);
        return;
      } else {
        _handshakeBuffer.addByte(byte);
      }
    }
  }

  @override
  Future<void> sendFrame(Uint8List frame) async {
    // FrameCodec writes a 4-byte big-endian length prefix so the receiver
    // can reassemble messages regardless of how TCP chunked them. After
    // handshake, the frame body is AES-GCM-sealed with the PIN-derived
    // key so a passive listener on the LAN sees only ciphertext.
    final key = _sessionKey;
    final body = key == null ? frame : await _seal(frame, key);
    _socket.add(FrameCodec.encode(body));
    await _socket.flush();
  }

  @override
  Stream<Uint8List> incomingFrames() async* {
    await for (final framed in FrameCodec.decode(_incoming.stream)) {
      final key = _sessionKey;
      if (key == null) {
        yield framed;
        continue;
      }
      try {
        yield await _unseal(framed, key);
      } catch (_) {
        // Wrong key (PIN mismatch raced past the handshake check) or
        // tampered frame — drop it silently. v1.x can tear down the
        // session on first auth failure.
      }
    }
  }

  @override
  String get resumeToken => '';

  @override
  Future<void> close() async {
    await _subscription.cancel();
    try {
      await _socket.close();
    } catch (_) {}
    if (!_incoming.isClosed) await _incoming.close();
  }
}
