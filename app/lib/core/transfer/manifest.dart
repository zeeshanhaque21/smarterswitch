import 'dart:convert';
import 'dart:typed_data';

import '../../state/transfer_state.dart';

/// Sender-side declaration of what's about to be transferred. Sent as the
/// first framed message after pairing. The receiver uses this to:
/// - render counts of incoming data on the Scan screen,
/// - kick off its local dedup index for each declared category,
/// - sanity-check the next framed messages against the manifest.
///
/// JSON-encoded for v0.2; switch to protobuf when the schema stabilizes
/// (per `docs/usb-c-spike.md` and the protocol-layer plan).
class TransferManifest {
  const TransferManifest({
    required this.senderDisplayName,
    required this.categories,
    required this.counts,
  });

  /// What the sender calls itself. Surfaced in receiver UI as
  /// "Receiving from \<senderDisplayName>".
  final String senderDisplayName;

  /// Categories the sender intends to transfer. The receiver should NOT
  /// expect data for any other category, even if it has its own selection.
  final List<DataCategory> categories;

  /// Per-category record count on the sender. The actual number transferred
  /// after dedup may be lower; this is the upper bound.
  final Map<DataCategory, int> counts;

  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode({
        'kind': 'manifest',
        'sender': senderDisplayName,
        'categories': [for (final c in categories) c.name],
        'counts': {
          for (final entry in counts.entries) entry.key.name: entry.value,
        },
      })));

  static TransferManifest fromBytes(Uint8List bytes) {
    final raw = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (raw['kind'] != 'manifest') {
      throw FormatException('Not a manifest frame: ${raw['kind']}');
    }
    final categoryNames =
        (raw['categories'] as List<dynamic>).cast<String>();
    final categories = [
      for (final name in categoryNames)
        DataCategory.values.firstWhere((c) => c.name == name),
    ];
    final rawCounts = (raw['counts'] as Map<String, dynamic>);
    final counts = <DataCategory, int>{
      for (final c in categories)
        c: (rawCounts[c.name] as num?)?.toInt() ?? 0,
    };
    return TransferManifest(
      senderDisplayName: raw['sender'] as String? ?? 'Other phone',
      categories: categories,
      counts: counts,
    );
  }
}
