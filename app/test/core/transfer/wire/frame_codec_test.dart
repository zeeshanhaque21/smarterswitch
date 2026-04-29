import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smarterswitch/core/transfer/wire/frame_codec.dart';

Stream<Uint8List> _stream(List<List<int>> chunks) async* {
  for (final c in chunks) {
    yield Uint8List.fromList(c);
  }
}

void main() {
  group('FrameCodec.encode', () {
    test('writes 4-byte big-endian length prefix', () {
      final encoded = FrameCodec.encode(Uint8List.fromList([1, 2, 3]));
      expect(encoded.sublist(0, 4), [0, 0, 0, 3]);
      expect(encoded.sublist(4), [1, 2, 3]);
    });

    test('rejects frames over the max size', () {
      // Build a synthetic over-sized payload via a Uint8List of the wrong
      // length-class — actually allocating 64 MB+ in tests is wasteful.
      // We trigger the check by instantiating a typed list bigger than the
      // limit only in length, not in actual storage; here, we mock by
      // setting a too-large length and using a small backing list — but
      // ArgumentError fires before we look at content, so this is fine.
      expect(
        () => FrameCodec.encode(Uint8List(FrameCodec.maxFrameSize + 1)),
        throwsArgumentError,
      );
    });
  });

  group('FrameCodec.decode', () {
    test('round-trips a single frame', () async {
      final payload = Uint8List.fromList([10, 20, 30, 40]);
      final encoded = FrameCodec.encode(payload);
      final decoded = await FrameCodec.decode(_stream([encoded])).first;
      expect(decoded, payload);
    });

    test('handles a stream that splits the length prefix', () async {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final encoded = FrameCodec.encode(payload);
      // Split into a 2-byte prefix-half and the rest.
      final chunks = [
        encoded.sublist(0, 2),
        encoded.sublist(2),
      ];
      final decoded =
          await FrameCodec.decode(_stream(chunks)).first;
      expect(decoded, payload);
    });

    test('handles a stream that splits the payload', () async {
      final payload = Uint8List.fromList(
        List<int>.generate(100, (i) => i % 256),
      );
      final encoded = FrameCodec.encode(payload);
      // Random split partway through the payload.
      final chunks = [
        encoded.sublist(0, 30),
        encoded.sublist(30, 70),
        encoded.sublist(70),
      ];
      final decoded =
          await FrameCodec.decode(_stream(chunks)).first;
      expect(decoded, payload);
    });

    test('handles multiple frames concatenated', () async {
      final a = Uint8List.fromList([1, 2]);
      final b = Uint8List.fromList([3, 4, 5]);
      final c = Uint8List.fromList([6]);
      final stream = _stream([
        FrameCodec.encode(a),
        FrameCodec.encode(b),
        FrameCodec.encode(c),
      ]);
      final result = await FrameCodec.decode(stream).toList();
      expect(result, [a, b, c]);
    });

    test('handles many frames in a single chunk', () async {
      final encA = FrameCodec.encode(Uint8List.fromList([1]));
      final encB = FrameCodec.encode(Uint8List.fromList([2, 2]));
      final encC = FrameCodec.encode(Uint8List.fromList([3, 3, 3]));
      // All three encoded buffers concatenated in a single chunk.
      final all = BytesBuilder()
        ..add(encA)
        ..add(encB)
        ..add(encC);
      final stream = _stream([all.toBytes()]);
      final result = await FrameCodec.decode(stream).toList();
      expect(result, [
        [1],
        [2, 2],
        [3, 3, 3],
      ]);
    });

    test('rejects an oversized length prefix from the wire', () async {
      // Length prefix says 64 MB + 1; we should throw rather than allocate.
      final tooLarge = ByteData(4)
        ..setUint32(0, FrameCodec.maxFrameSize + 1, Endian.big);
      final stream = _stream([tooLarge.buffer.asUint8List()]);
      expect(
        () async => await FrameCodec.decode(stream).toList(),
        throwsA(isA<FormatException>()),
      );
    });

    test('zero-length frame round-trips', () async {
      final encoded = FrameCodec.encode(Uint8List(0));
      final decoded = await FrameCodec.decode(_stream([encoded])).first;
      expect(decoded, isEmpty);
    });
  });
}
