import 'dart:convert';
import 'dart:typed_data';

import '../../state/transfer_state.dart';
import '../model/calendar_event.dart';
import '../model/call_log_record.dart';
import '../model/contact.dart';
import '../model/media_record.dart';
import '../model/sms_record.dart';

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
      case 'sms_record':
        return SmsRecordEnvelope(
          SmsRecordCodec.fromJson(raw['record'] as Map<String, dynamic>),
        );
      case 'media_start':
        return MediaStartEnvelope(
          MediaHeaderCodec.fromJson(raw['header'] as Map<String, dynamic>),
        );
      case 'media_chunk':
        return MediaChunkEnvelope(
          sha256: raw['sha256'] as String,
          offset: (raw['offset'] as num).toInt(),
          base64Bytes: raw['bytes'] as String,
        );
      case 'media_end':
        return MediaEndEnvelope(sha256: raw['sha256'] as String);
      case 'photo_hashes':
        // v0.13+: 'entries' carries {sha256, phash}. Older 'hashes' was
        // a bare List<String> of sha256s — handled per-element via
        // PhotoHashEntry.fromJson back-compat.
        final rawEntries = (raw['entries'] as List<dynamic>?) ??
            (raw['hashes'] as List<dynamic>?) ??
            const [];
        return PhotoHashesEnvelope(
          entries: [
            for (final e in rawEntries) PhotoHashEntry.fromJson(e),
          ],
        );
      case 'photo_skip_list':
        return PhotoSkipListEnvelope(
          skip: ((raw['skip'] as List<dynamic>?) ?? const [])
              .cast<String>()
              .toList(growable: false),
        );
      case 'contact_record':
        return ContactRecordEnvelope(
          ContactCodec.fromJson(raw['record'] as Map<String, dynamic>),
        );
      case 'calendar_record':
        return CalendarEventEnvelope(
          CalendarEventCodec.fromJson(raw['record'] as Map<String, dynamic>),
        );
      case 'category_done':
        return CategoryDoneEnvelope(
          DataCategory.values.firstWhere(
            (c) => c.name == raw['category'],
          ),
        );
      case 'transfer_done':
        return const TransferDoneEnvelope();
      case 'record_ack':
        return RecordAckEnvelope(
          category: DataCategory.values.firstWhere(
            (c) => c.name == raw['category'],
            orElse: () => DataCategory.sms,
          ),
          count: (raw['count'] as num?)?.toInt() ?? 0,
        );
      case 'heartbeat':
        return const HeartbeatEnvelope();
      case 'resume':
        return ResumeEnvelope(
          watermarks: {
            for (final entry
                in (raw['watermarks'] as Map<String, dynamic>? ?? const {})
                    .entries)
              DataCategory.values.firstWhere(
                (c) => c.name == entry.key,
                orElse: () => DataCategory.sms,
              ): (entry.value as num).toInt(),
          },
        );
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

class SmsRecordEnvelope extends TransferEnvelope {
  SmsRecordEnvelope(this.record);
  final SmsRecord record;
  @override
  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode({
        'kind': 'sms_record',
        'record': SmsRecordCodec.toJson(record),
      })));
}

/// Header for one photo / video about to stream. Followed by N
/// MediaChunkEnvelope frames and finally a MediaEndEnvelope. The receiver
/// can short-circuit on sha256 match — sender still streams chunks (the
/// receiver discards them) so we don't need a bidirectional skip protocol
/// in v0.7. Bandwidth waste on duplicates is the trade-off; v0.8 adds a
/// pre-flight hash manifest.
class MediaStartEnvelope extends TransferEnvelope {
  MediaStartEnvelope(this.header);
  final MediaHeader header;
  @override
  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode({
        'kind': 'media_start',
        'header': MediaHeaderCodec.toJson(header),
      })));
}

class MediaChunkEnvelope extends TransferEnvelope {
  MediaChunkEnvelope({
    required this.sha256,
    required this.offset,
    required this.base64Bytes,
  });
  final String sha256;
  final int offset;
  final String base64Bytes;
  @override
  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode({
        'kind': 'media_chunk',
        'sha256': sha256,
        'offset': offset,
        'bytes': base64Bytes,
      })));
}

class MediaEndEnvelope extends TransferEnvelope {
  MediaEndEnvelope({required this.sha256});
  final String sha256;
  @override
  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode({
        'kind': 'media_end',
        'sha256': sha256,
      })));
}

/// One entry in the pre-flight photo hash list. Carries both an exact
/// sha256 and an optional 64-bit perceptual hash. The pHash is null for
/// images Android can't decode natively (videos, some RAW formats).
class PhotoHashEntry {
  const PhotoHashEntry({required this.sha256, this.pHash});
  final String sha256;
  final int? pHash;

  Map<String, dynamic> toJson() => {
        'sha256': sha256,
        if (pHash != null) 'phash': pHash,
      };

  static PhotoHashEntry fromJson(Object? raw) {
    if (raw is String) {
      // Back-compat: v0.12 and earlier sent bare sha256 strings.
      return PhotoHashEntry(sha256: raw);
    }
    final m = raw as Map<String, dynamic>;
    return PhotoHashEntry(
      sha256: m['sha256'] as String,
      pHash: (m['phash'] as num?)?.toInt(),
    );
  }
}

/// Pre-flight hash list from sender → receiver, before any photo bytes
/// flow. Receiver replies with [PhotoSkipListEnvelope] naming the hashes
/// it already has; sender then streams only the misses. v0.13 added
/// pHash alongside sha256 so the receiver can also surface fuzzy matches
/// (re-encoded copies of the same image, different bytes, near-identical
/// pHash).
class PhotoHashesEnvelope extends TransferEnvelope {
  PhotoHashesEnvelope({required this.entries});
  final List<PhotoHashEntry> entries;
  @override
  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode({
        'kind': 'photo_hashes',
        'entries': [for (final e in entries) e.toJson()],
      })));
}

class PhotoSkipListEnvelope extends TransferEnvelope {
  PhotoSkipListEnvelope({required this.skip});
  final List<String> skip;
  @override
  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode({
        'kind': 'photo_skip_list',
        'skip': skip,
      })));
}

class MediaHeader {
  const MediaHeader({
    required this.sha256,
    required this.fileName,
    required this.byteSize,
    required this.mimeType,
    required this.kind,
    this.takenAtMs,
  });
  final String sha256;
  final String fileName;
  final int byteSize;
  final String mimeType;
  final MediaKind kind;
  final int? takenAtMs;
}

class MediaHeaderCodec {
  static Map<String, dynamic> toJson(MediaHeader h) => {
        'sha256': h.sha256,
        'fileName': h.fileName,
        'byteSize': h.byteSize,
        'mimeType': h.mimeType,
        'kind': h.kind == MediaKind.video ? 'video' : 'image',
        'takenAtMs': h.takenAtMs,
      };

  static MediaHeader fromJson(Map<String, dynamic> m) => MediaHeader(
        sha256: m['sha256'] as String,
        fileName: m['fileName'] as String? ?? '',
        byteSize: (m['byteSize'] as num?)?.toInt() ?? 0,
        mimeType: m['mimeType'] as String? ?? 'application/octet-stream',
        kind:
            (m['kind'] as String?) == 'video' ? MediaKind.video : MediaKind.image,
        takenAtMs: (m['takenAtMs'] as num?)?.toInt(),
      );
}

class ContactRecordEnvelope extends TransferEnvelope {
  ContactRecordEnvelope(this.record);
  final Contact record;
  @override
  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode({
        'kind': 'contact_record',
        'record': ContactCodec.toJson(record),
      })));
}

class CalendarEventEnvelope extends TransferEnvelope {
  CalendarEventEnvelope(this.record);
  final CalendarEvent record;
  @override
  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode({
        'kind': 'calendar_record',
        'record': CalendarEventCodec.toJson(record),
      })));
}

/// Sender → receiver "I'm still alive" tick. Emitted every few seconds
/// during long pauses (notably the photo pre-flight hashing pass) so
/// the receiver's incoming-frames stream sees traffic and the OS / Wi-Fi
/// power management doesn't tear down an idle TCP socket. Receiver
/// handles it as a no-op.
class HeartbeatEnvelope extends TransferEnvelope {
  const HeartbeatEnvelope();
  @override
  Uint8List toBytes() =>
      Uint8List.fromList(utf8.encode(jsonEncode({'kind': 'heartbeat'})));
}

/// Receiver → sender, sent at the start of each transfer session.
/// Carries the highest sequence number the receiver has successfully
/// written per category from any prior session. Sender skips that many
/// records before resuming the stream — so a Wi-Fi drop mid-photo-transfer
/// doesn't restart SMS from zero on reconnect.
///
/// First-time transfers send watermarks of 0 (or no entry) per category,
/// which is identical to "start from the beginning."
class ResumeEnvelope extends TransferEnvelope {
  ResumeEnvelope({required this.watermarks});
  final Map<DataCategory, int> watermarks;
  @override
  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode({
        'kind': 'resume',
        'watermarks': {
          for (final e in watermarks.entries) e.key.name: e.value,
        },
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

/// Receiver → sender, emitted after each record envelope is processed
/// (dedup decision made and the record queued for write or marked
/// skipped). [count] is the receiver's running per-category total of
/// processed records, so the sender's progress bar can drive directly
/// off the receiver's confirmed-integrated count instead of its own
/// optimistic send counter.
class RecordAckEnvelope extends TransferEnvelope {
  const RecordAckEnvelope({required this.category, required this.count});
  final DataCategory category;
  final int count;
  @override
  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode({
        'kind': 'record_ack',
        'category': category.name,
        'count': count,
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

class SmsRecordCodec {
  static Map<String, dynamic> toJson(SmsRecord r) => {
        'address': r.address,
        'body': r.body,
        'timestampMs': r.timestampMs,
        'type': r.type.name,
        'threadId': r.threadId,
        // mmsParts is part of the model but not yet wired through the
        // platform reader; carry it on the wire so v0.7+ MMS work doesn't
        // need a schema change.
        'mmsParts': r.mmsParts,
      };

  static SmsRecord fromJson(Map<String, dynamic> m) => SmsRecord(
        address: m['address'] as String? ?? '',
        body: m['body'] as String? ?? '',
        timestampMs: (m['timestampMs'] as num?)?.toInt() ?? 0,
        type: SmsType.values.firstWhere(
          (t) => t.name == m['type'],
          orElse: () => SmsType.inbox,
        ),
        threadId: (m['threadId'] as num?)?.toInt(),
        mmsParts: ((m['mmsParts'] as List<dynamic>?) ?? const [])
            .cast<String>()
            .toList(growable: false),
      );
}

class ContactCodec {
  static Map<String, dynamic> toJson(Contact c) => {
        'displayName': c.displayName,
        'sourceAccountType': c.sourceAccountType,
        'phones': c.phones,
        'emails': c.emails,
      };

  static Contact fromJson(Map<String, dynamic> m) => Contact(
        displayName: m['displayName'] as String? ?? '',
        sourceAccountType: m['sourceAccountType'] as String?,
        phones: ((m['phones'] as List<dynamic>?) ?? const [])
            .cast<String>()
            .toList(growable: false),
        emails: ((m['emails'] as List<dynamic>?) ?? const [])
            .cast<String>()
            .toList(growable: false),
      );
}

class CalendarEventCodec {
  static Map<String, dynamic> toJson(CalendarEvent e) => {
        'uid': e.uid,
        'title': e.title,
        'location': e.location,
        'startUtcMs': e.startUtcMs,
        'endUtcMs': e.endUtcMs,
        'allDay': e.allDay,
        'recurrence': e.recurrence,
      };

  static CalendarEvent fromJson(Map<String, dynamic> m) => CalendarEvent(
        uid: m['uid'] as String?,
        title: m['title'] as String? ?? '',
        location: m['location'] as String? ?? '',
        startUtcMs: (m['startUtcMs'] as num?)?.toInt() ?? 0,
        endUtcMs: (m['endUtcMs'] as num?)?.toInt() ?? 0,
        allDay: m['allDay'] as bool? ?? false,
        recurrence: m['recurrence'] as String?,
      );
}
