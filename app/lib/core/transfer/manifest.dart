import 'dart:convert';
import 'dart:typed_data';

import '../../state/transfer_state.dart';
import '../model/call_log_record.dart';

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

/// Wire envelope for everything that follows the manifest. One frame per
/// envelope; the receiver dispatches by [kind].
///
/// Keeping it untyped-JSON for v0.4 — protobuf migration is in the plan
/// once the schema settles. The cost is slightly larger frames; benefit
/// is zero codegen toolchain.
sealed class TransferEnvelope {
  const TransferEnvelope();

  Uint8List toBytes();

  static TransferEnvelope fromBytes(Uint8List bytes) {
    final raw = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    switch (raw['kind']) {
      case 'manifest':
        // Round-trip back through TransferManifest so callers can match
        // on a single envelope hierarchy.
        return ManifestEnvelope(TransferManifest.fromBytes(bytes));
      case 'call_log_record':
        return CallLogRecordEnvelope(
          CallLogRecordCodec.fromJson(raw['record'] as Map<String, dynamic>),
        );
      case 'category_done':
        return CategoryDoneEnvelope(
          DataCategory.values.firstWhere(
            (c) => c.name == raw['category'],
          ),
        );
      case 'transfer_done':
        return const TransferDoneEnvelope();
      default:
        throw FormatException('Unknown envelope kind: ${raw['kind']}');
    }
  }
}

class ManifestEnvelope extends TransferEnvelope {
  ManifestEnvelope(this.manifest);
  final TransferManifest manifest;
  @override
  Uint8List toBytes() => manifest.toBytes();
}

class CallLogRecordEnvelope extends TransferEnvelope {
  CallLogRecordEnvelope(this.record);
  final CallLogRecord record;
  @override
  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode({
        'kind': 'call_log_record',
        'record': CallLogRecordCodec.toJson(record),
      })));
}

class CategoryDoneEnvelope extends TransferEnvelope {
  CategoryDoneEnvelope(this.category);
  final DataCategory category;
  @override
  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode({
        'kind': 'category_done',
        'category': category.name,
      })));
}

class TransferDoneEnvelope extends TransferEnvelope {
  const TransferDoneEnvelope();
  @override
  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode({
        'kind': 'transfer_done',
      })));
}

class CallLogRecordCodec {
  static Map<String, dynamic> toJson(CallLogRecord r) => {
        'number': r.number,
        'timestampMs': r.timestampMs,
        'durationSeconds': r.durationSeconds,
        'direction': r.direction.name,
        'cachedName': r.cachedName,
      };

  static CallLogRecord fromJson(Map<String, dynamic> m) => CallLogRecord(
        number: m['number'] as String? ?? '',
        timestampMs: (m['timestampMs'] as num?)?.toInt() ?? 0,
        durationSeconds: (m['durationSeconds'] as num?)?.toInt() ?? 0,
        direction: CallDirection.values.firstWhere(
          (d) => d.name == m['direction'],
          orElse: () => CallDirection.incoming,
        ),
        cachedName: m['cachedName'] as String?,
      );
}
