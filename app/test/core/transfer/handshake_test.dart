import 'package:flutter_test/flutter_test.dart';
import 'package:smarterswitch/core/transfer/handshake.dart';

void main() {
  group('Handshake', () {
    test('two peers with the same PIN derive the same key', () async {
      final alice = await Handshake.generate();
      final bob = await Handshake.generate();

      final aliceKey = await Handshake.deriveSharedKey(
        myKeyPair: alice,
        peerPublicKey: bob.publicKeyBytes,
        pin: '123456',
      );
      final bobKey = await Handshake.deriveSharedKey(
        myKeyPair: bob,
        peerPublicKey: alice.publicKeyBytes,
        pin: '123456',
      );

      expect(aliceKey, bobKey);
      expect(aliceKey, hasLength(32));
    });

    test('different PINs produce different keys', () async {
      final alice = await Handshake.generate();
      final bob = await Handshake.generate();

      final aliceKey = await Handshake.deriveSharedKey(
        myKeyPair: alice,
        peerPublicKey: bob.publicKeyBytes,
        pin: '123456',
      );
      final bobKey = await Handshake.deriveSharedKey(
        myKeyPair: bob,
        peerPublicKey: alice.publicKeyBytes,
        pin: '999999',
      );
      expect(aliceKey, isNot(equals(bobKey)));
    });

    test('different runs of generate produce different public keys', () async {
      final a = await Handshake.generate();
      final b = await Handshake.generate();
      expect(a.publicKeyBytes, isNot(equals(b.publicKeyBytes)));
    });

    test('PIN entropy: a one-character flip produces a statistically '
        'unrelated key', () async {
      final alice = await Handshake.generate();
      final bob = await Handshake.generate();

      final k1 = await Handshake.deriveSharedKey(
        myKeyPair: alice,
        peerPublicKey: bob.publicKeyBytes,
        pin: '123456',
      );
      final k2 = await Handshake.deriveSharedKey(
        myKeyPair: alice,
        peerPublicKey: bob.publicKeyBytes,
        pin: '123450',
      );
      // Sanity: should differ in at least 96 of 256 bits (well above what
      // any meaningful collision would imply).
      var diffBits = 0;
      for (var i = 0; i < k1.length; i++) {
        diffBits += _popcount(k1[i] ^ k2[i]);
      }
      expect(diffBits, greaterThanOrEqualTo(96));
    });

    test('changing the info label produces a different key', () async {
      final alice = await Handshake.generate();
      final bob = await Handshake.generate();

      final defaultLabel = await Handshake.deriveSharedKey(
        myKeyPair: alice,
        peerPublicKey: bob.publicKeyBytes,
        pin: '123456',
      );
      final customLabel = await Handshake.deriveSharedKey(
        myKeyPair: alice,
        peerPublicKey: bob.publicKeyBytes,
        pin: '123456',
        infoLabel: 'smarterswitch/v2/session-key',
      );
      expect(defaultLabel, isNot(equals(customLabel)));
    });
  });
}

int _popcount(int b) {
  var v = b & 0xff;
  v = v - ((v >> 1) & 0x55);
  v = (v & 0x33) + ((v >> 2) & 0x33);
  return (v + (v >> 4)) & 0x0f;
}
