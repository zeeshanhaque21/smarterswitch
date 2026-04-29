import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smarterswitch/core/transfer/in_memory_transport.dart';

void main() {
  group('InMemoryTransport', () {
    test('two transports on the same hub pair successfully', () async {
      final hub = InMemoryHub();
      final receiver = InMemoryTransport(hub: hub, localId: 'pixel-7');
      final sender = InMemoryTransport(hub: hub, localId: 's23');

      await receiver.advertise(displayName: 'Pixel 7');
      final pairFuture = receiver.accept(pin: '123456');

      // Sender side: discover, find Pixel, connect.
      final peer = await sender.discover().first;
      expect(peer.displayName, 'Pixel 7');

      final senderSession = await sender.connect(peer, pin: '123456');
      final receiverSession = await pairFuture;

      expect(senderSession.peerDisplayName, 'Pixel 7');
      expect(receiverSession.peerDisplayName, 's23');
    });

    test('frames sent on one side arrive on the other', () async {
      final hub = InMemoryHub();
      final receiver = InMemoryTransport(hub: hub, localId: 'pixel-7');
      final sender = InMemoryTransport(hub: hub, localId: 's23');

      await receiver.advertise(displayName: 'Pixel 7');
      final pairFuture = receiver.accept(pin: '111222');
      final peer = await sender.discover().first;
      final senderSession = await sender.connect(peer, pin: '111222');
      final receiverSession = await pairFuture;

      final inbox = <List<int>>[];
      receiverSession.incomingFrames().listen(inbox.add);

      await senderSession.sendFrame(Uint8List.fromList([1, 2, 3]));
      await senderSession.sendFrame(Uint8List.fromList([4, 5, 6]));

      // Allow scheduled microtasks to drain.
      await Future<void>.delayed(Duration.zero);

      expect(inbox, [
        [1, 2, 3],
        [4, 5, 6],
      ]);
    });

    test('wrong PIN rejects without exposing the session', () async {
      final hub = InMemoryHub();
      final receiver = InMemoryTransport(hub: hub, localId: 'pixel-7');
      final sender = InMemoryTransport(hub: hub, localId: 's23');

      await receiver.advertise(displayName: 'Pixel 7');
      // ignore: unawaited_futures
      receiver.accept(pin: 'CORRECT');
      final peer = await sender.discover().first;

      await expectLater(
        sender.connect(peer, pin: 'WRONG'),
        throwsA(isA<PinMismatchException>()),
      );

      // After the wrong-PIN reject, the right PIN should still succeed
      // — the advert stays alive, mirroring what real transports do.
      final session = await sender.connect(peer, pin: 'CORRECT');
      expect(session.peerDisplayName, 'Pixel 7');
    });

    test('close() shuts down the outgoing channel', () async {
      final hub = InMemoryHub();
      final receiver = InMemoryTransport(hub: hub, localId: 'pixel-7');
      final sender = InMemoryTransport(hub: hub, localId: 's23');

      await receiver.advertise(displayName: 'Pixel 7');
      final pairFuture = receiver.accept(pin: '000000');
      final peer = await sender.discover().first;
      final senderSession = await sender.connect(peer, pin: '000000');
      await pairFuture;

      await senderSession.close();

      await expectLater(
        senderSession.sendFrame(Uint8List.fromList([1])),
        throwsA(isA<StateError>()),
      );
    });
  });
}
