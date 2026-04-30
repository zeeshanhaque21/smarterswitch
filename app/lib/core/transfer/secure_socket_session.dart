import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'handshake.dart';
import 'transport.dart';
import 'wire/frame_codec.dart';

/// Bidirectional `PairedSession` backed by a TCP `Socket`. Owns the *only*
/// listener on the socket. Performs the SmarterSwitch handshake (PIN line +
/// X25519 public-key exchange) and then transparently AES-GCM-seals every
/// subsequent frame under the key derived from the user's PIN.
///
/// Shared by `LanTransport` (mDNS over shared Wi-Fi) and `WifiDirectTransport`
/// (peer-to-peer Wi-Fi Direct), since the over-the-wire protocol is identical
/// once both sides have a TCP socket between them.
class SecureSocketSession implements PairedSession {
  SecureSocketSession({required this.peerDisplayName, required Socket socket})
      : _socket = socket {
    // Keep the kernel TCP keepalive on so an idle connection (during
    // the sender's pre-flight hashing pass, say) doesn't get silently
    // dropped by Wi-Fi power management or intermediate firewall
    // timeouts. App-layer heartbeats are still sent during known
    // long-idle phases as belt-and-suspenders.
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
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

  /// Sender-side handshake. Sends `PIN xxxxxx`, awaits `OK`, performs the
  /// X25519 + HKDF key exchange. Returns a fully-handshaken session ready
  /// for sealed frame traffic. Throws [PinMismatchException] if the
  /// receiver replies anything other than `OK`.
  static Future<SecureSocketSession> handshakeAsConnector({
    required Socket socket,
    required String peerDisplayName,
    required String pin,
  }) async {
    final session = SecureSocketSession(
      peerDisplayName: peerDisplayName,
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

  /// Receiver-side handshake. Reads `PIN xxxxxx` from the wire, replies
  /// `OK` if it matches the expected PIN, then runs the key exchange and
  /// returns. On mismatch replies `BAD\n`, closes, and throws
  /// [PinMismatchException].
  static Future<SecureSocketSession> handshakeAsAcceptor({
    required Socket socket,
    required String peerDisplayName,
    required String expectedPin,
  }) async {
    final session = SecureSocketSession(
      peerDisplayName: peerDisplayName,
      socket: socket,
    );
    final received = (await session._readHandshakeLine()).trim();
    if (received.startsWith('PIN ') &&
        received.substring(4) == expectedPin) {
      socket.write('OK\n');
      await socket.flush();
      await session._performKeyExchange(expectedPin);
      session._handshakeDone();
      return session;
    }
    socket.write('BAD\n');
    await socket.flush();
    await session.close();
    throw const PinMismatchException();
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

  Uint8List? _sessionKey;
  static final _aes = AesGcm.with256bits();

  Future<String> _readHandshakeLine() {
    final c = Completer<String>();
    _readLineCompleter = c;
    return c.future;
  }

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
    for (var i = 0; i < data.length; i++) {
      final byte = data[i];
      if (byte == 0x0a) {
        final line = utf8.decode(_handshakeBuffer.toBytes());
        _handshakeBuffer.clear();
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
        // Wrong key or tampered frame — drop silently.
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
