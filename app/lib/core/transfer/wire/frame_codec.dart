import 'dart:async';
import 'dart:typed_data';

/// Length-prefixed frame codec. Each frame is `[uint32 BE length][payload]`.
///
/// The Transport layer below this is responsible for the link itself; the
/// protocol layer above this hands typed messages (`Hello`, `Manifest`,
/// `Record`, `Ack`, `Resume`) which get serialized to bytes elsewhere and
/// passed in here. The codec is therefore agnostic to message content — it
/// only cares about getting bytes across the wire.
///
/// Why uint32 length and not varint: 4 GB is far above any realistic single
/// frame for the protocol (a single SMS is < 2 KB; the largest frame would
/// be one Manifest entry per record, ~hundreds of KB at the high end). 4
/// bytes of overhead per frame is negligible at our message sizes; varint
/// would save ~3 bytes per small frame at the cost of much fussier code.
class FrameCodec {
  /// Maximum allowed frame size, defensive. Catches malformed length
  /// prefixes (e.g. peer sent garbage) before we allocate huge buffers.
  /// Set to 64 MB; nothing in our protocol approaches this.
  static const int maxFrameSize = 64 * 1024 * 1024;

  /// Encode one frame: `[length: uint32 BE][payload]`.
  static Uint8List encode(Uint8List payload) {
    if (payload.length > maxFrameSize) {
      throw ArgumentError(
          'Frame too large (${payload.length} > $maxFrameSize)');
    }
    final out = Uint8List(4 + payload.length);
    final bd = ByteData.view(out.buffer);
    bd.setUint32(0, payload.length, Endian.big);
    out.setRange(4, 4 + payload.length, payload);
    return out;
  }

  /// Decode a stream of length-prefixed frames out of an arbitrary byte
  /// stream. The byte stream's chunk boundaries do not need to align with
  /// frame boundaries — the codec buffers and emits one frame per
  /// completed `[length][payload]` pair.
  static Stream<Uint8List> decode(Stream<Uint8List> byteStream) async* {
    final buf = BytesBuilder(copy: false);
    var pendingLength = -1; // -1 means "still need to read the 4-byte length"

    await for (final chunk in byteStream) {
      buf.add(chunk);
      while (true) {
        if (pendingLength < 0) {
          if (buf.length < 4) break;
          final all = buf.toBytes();
          final bd = ByteData.view(all.buffer, all.offsetInBytes, all.length);
          pendingLength = bd.getUint32(0, Endian.big);
          if (pendingLength > maxFrameSize) {
            throw FormatException(
                'Frame too large: $pendingLength > $maxFrameSize');
          }
          // Consume the 4 length bytes from the buffer.
          buf.clear();
          buf.add(all.sublist(4));
        }
        if (buf.length < pendingLength) break;
        // Have a full frame.
        final all = buf.toBytes();
        final frame = Uint8List.fromList(all.sublist(0, pendingLength));
        buf.clear();
        buf.add(all.sublist(pendingLength));
        pendingLength = -1;
        yield frame;
      }
    }
  }
}
