import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// PIN-anchored authenticated key exchange.
///
/// Why we don't trust the link layer alone:
/// - Wi-Fi Direct's framework-chosen WPA2-PSK is opaque to the app — we
///   can't bind it to anything we control.
/// - mDNS over LAN runs over whatever the user's router provides,
///   sometimes nothing.
/// - The OS-level "accept connection" prompts on both transports are the
///   user's only authentication anchor, but they don't bind to our PIN.
///
/// So we run our own X25519 ECDH on top of the raw socket and mix the
/// 6-digit PIN into the HKDF salt. Wrong PIN ⇒ different derived key on
/// the two sides ⇒ MAC mismatch on the first authenticated message ⇒
/// clean reject before any protocol traffic flows.
///
/// This module is the pure-protocol piece — it produces the symmetric key
/// that downstream code uses to AES-GCM-seal each frame. The actual frame
/// encryption is wired in once the protocol layer above is wrapped.
class Handshake {
  /// One side of the handshake. Both peers create one of these, exchange
  /// their public-key bytes (via the first two protocol frames), and then
  /// both call [deriveSharedKey] with the peer's public key + the PIN.
  /// The two sides will derive the same 32-byte key iff they share the same
  /// PIN.
  static Future<HandshakeKeyPair> generate() async {
    final algo = X25519();
    final keyPair = await algo.newKeyPair();
    final pub = await keyPair.extractPublicKey();
    return HandshakeKeyPair._(keyPair: keyPair, publicKeyBytes: pub.bytes);
  }

  /// Derive the symmetric session key from `(myKeyPair, peerPublicKey, pin)`.
  ///
  /// Output: 32 bytes (AES-256-GCM key material). Symmetric across the two
  /// peers iff:
  /// - both used the same `pin`, AND
  /// - both used the same `infoLabel` (a constant — see below), AND
  /// - the public keys really were exchanged correctly (no MITM).
  ///
  /// The PIN is the salt to HKDF; even a 1-bit difference produces a
  /// statistically unrelated 32-byte output, so wrong-PIN derivations
  /// can never accidentally collide.
  static Future<Uint8List> deriveSharedKey({
    required HandshakeKeyPair myKeyPair,
    required List<int> peerPublicKey,
    required String pin,
    String infoLabel = 'smarterswitch/v1/session-key',
  }) async {
    final algo = X25519();
    final shared = await algo.sharedSecretKey(
      keyPair: myKeyPair._keyPair,
      remotePublicKey: SimplePublicKey(peerPublicKey, type: KeyPairType.x25519),
    );
    final sharedBytes = await shared.extractBytes();
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(sharedBytes),
      nonce: utf8.encode(pin),
      info: utf8.encode(infoLabel),
    );
    return Uint8List.fromList(await derived.extractBytes());
  }
}

class HandshakeKeyPair {
  HandshakeKeyPair._({
    required SimpleKeyPair keyPair,
    required this.publicKeyBytes,
  }) : _keyPair = keyPair;

  final SimpleKeyPair _keyPair;

  /// Send these bytes to the peer as your handshake-Hello payload.
  final List<int> publicKeyBytes;
}
