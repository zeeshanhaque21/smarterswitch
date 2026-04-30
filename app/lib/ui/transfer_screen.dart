import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/dedup/calendar_dedup.dart';
import '../core/dedup/call_log_dedup.dart';
import '../core/dedup/contacts_dedup.dart';
import '../core/dedup/sms_dedup.dart';
import '../core/model/calendar_event.dart';
import '../core/model/call_log_record.dart';
import '../core/model/contact.dart';
import '../core/model/sms_record.dart';
import '../core/transfer/manifest.dart';
import '../core/transfer/transport.dart';
import '../platform/calendar_reader.dart';
import '../platform/call_log_reader.dart';
import '../platform/contacts_reader.dart';
import '../platform/media_reader.dart';
import '../platform/sms_reader.dart';
import '../state/transfer_state.dart';

/// Real per-category transfer.
///
/// Sender side: walk the manifest categories, read full records via the
/// platform channel, send each as a CallLogRecordEnvelope frame, send a
/// CategoryDoneEnvelope between categories, end with a TransferDoneEnvelope.
///
/// Receiver side: subscribe to incoming envelopes; for call-log records,
/// build a dedup index of the local call log first, then write only the
/// non-duplicates via the platform channel. Tally written / skipped.
///
/// v0.4 covers the call-log path end-to-end. The other categories'
/// readers/writers land in v0.5+ but plug into the same envelope flow.
class TransferScreen extends ConsumerStatefulWidget {
  const TransferScreen({super.key});

  @override
  ConsumerState<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends ConsumerState<TransferScreen> {
  /// Per-category running tally of items *processed* on this side. On the
  /// sender, "processed" = sent. On the receiver, "processed" = received +
  /// dedup-decided + (if new) written.
  final Map<DataCategory, int> _processed = {};
  final Map<DataCategory, int> _writtenByCategory = {};
  final Map<DataCategory, int> _skippedByCategory = {};
  bool _done = false;
  String? _error;
  StreamSubscription? _incomingSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _incomingSub?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final state = ref.read(transferStateProvider);
    final session = state.pairedSession;
    final manifest = state.senderManifest;
    if (session == null || manifest == null) {
      setState(() => _error = 'No active session.');
      return;
    }
    try {
      if (state.role == DeviceRole.sender) {
        await _runAsSender(session, manifest);
      } else {
        await _runAsReceiver(session, manifest);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }
    if (mounted) {
      ref
          .read(transferStateProvider.notifier)
          .setTransferTallies(_writtenByCategory, _skippedByCategory);
      setState(() => _done = true);
      // Brief pause so the user sees the 100% state before we route.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (mounted) context.go('/done');
    }
  }

  Future<void> _runAsSender(
    PairedSession session,
    TransferManifest manifest,
  ) async {
    for (final category in manifest.categories) {
      _processed[category] = 0;
      switch (category) {
        case DataCategory.sms:
          final records = await SmsReader().readAll();
          for (final r in records) {
            await session.sendFrame(SmsRecordEnvelope(r).toBytes());
            _processed[category] = (_processed[category] ?? 0) + 1;
            if (mounted) setState(() {});
          }
          break;
        case DataCategory.callLog:
          final records = await CallLogReader().readAll();
          for (final r in records) {
            await session.sendFrame(CallLogRecordEnvelope(r).toBytes());
            _processed[category] = (_processed[category] ?? 0) + 1;
            if (mounted) setState(() {});
          }
          break;
        case DataCategory.contacts:
          final records = await ContactsReader().readAll();
          for (final r in records) {
            // Skip Google-synced contacts on the sender side — Google's own
            // sync handles them across devices, and we don't want to write
            // duplicates as on-device contacts on the receiver.
            if (r.isGoogleSynced) continue;
            await session.sendFrame(ContactRecordEnvelope(r).toBytes());
            _processed[category] = (_processed[category] ?? 0) + 1;
            if (mounted) setState(() {});
          }
          break;
        case DataCategory.calendar:
          final records = await CalendarReader().readAll();
          for (final r in records) {
            await session.sendFrame(CalendarEventEnvelope(r).toBytes());
            _processed[category] = (_processed[category] ?? 0) + 1;
            if (mounted) setState(() {});
          }
          break;
        case DataCategory.photos:
          await _streamPhotos(session, () {
            _processed[category] = (_processed[category] ?? 0) + 1;
            if (mounted) setState(() {});
          });
          break;
      }
      await session.sendFrame(CategoryDoneEnvelope(category).toBytes());
    }
    await session.sendFrame(const TransferDoneEnvelope().toBytes());
  }

  Future<void> _streamPhotos(
    PairedSession session,
    void Function() onFileDone,
  ) async {
    final reader = MediaReader();
    final files = await reader.readMetadata();
    for (final f in files) {
      String sha;
      try {
        sha = await reader.readSha256(f.uri);
      } catch (_) {
        // If a file becomes unreadable mid-walk (deleted, permissions
        // revoked), skip it and continue with the next.
        continue;
      }
      await session.sendFrame(MediaStartEnvelope(MediaHeader(
        sha256: sha,
        fileName: f.fileName,
        byteSize: f.byteSize,
        mimeType: f.mimeType,
        kind: f.kind,
        takenAtMs: f.takenAtMs,
      )).toBytes());
      var offset = 0;
      while (offset < f.byteSize) {
        final remaining = f.byteSize - offset;
        final chunkSize = remaining < MediaReader.chunkBytes
            ? remaining
            : MediaReader.chunkBytes;
        final bytes = await reader.readChunk(f.uri, offset, chunkSize);
        if (bytes.isEmpty) break;
        await session.sendFrame(MediaChunkEnvelope(
          sha256: sha,
          offset: offset,
          base64Bytes: base64.encode(bytes),
        ).toBytes());
        offset += bytes.length;
      }
      await session.sendFrame(MediaEndEnvelope(sha256: sha).toBytes());
      onFileDone();
    }
  }

  Future<void> _runAsReceiver(
    PairedSession session,
    TransferManifest manifest,
  ) async {
    // Build per-category dedup indexes from what already exists locally,
    // so incoming records that match get skipped instead of duplicated.
    final callLogIndex = manifest.categories.contains(DataCategory.callLog)
        ? CallLogDedup.indexOf(await CallLogReader().readAll())
        : <CallLogDedupKey>{};
    final contactsKeys = manifest.categories.contains(DataCategory.contacts)
        ? <Set<String>>[
            for (final c in await ContactsReader().readAll())
              ContactsDedup.matchKeysFor(c),
          ]
        : <Set<String>>[];
    final calendarIndex = manifest.categories.contains(DataCategory.calendar)
        ? CalendarDedup.indexOf(await CalendarReader().readAll())
        : <CalendarDedupKey>{};
    final smsIndex = manifest.categories.contains(DataCategory.sms)
        ? SmsDedup.indexOf(await SmsReader().readAll())
        : <SmsDedupKey>{};

    final pendingCallLogWrites = <CallLogRecord>[];
    final pendingContactWrites = <Contact>[];
    final pendingCalendarWrites = <CalendarEvent>[];
    final pendingSmsWrites = <SmsRecord>[];

    // Photos: streaming-by-sha256. Either we're skipping (sha256 already on
    // device) or actively writing (MediaStore stream open in Kotlin land).
    final mediaReader = MediaReader();
    final localMediaShas =
        manifest.categories.contains(DataCategory.photos)
            ? <String>{
                for (final m in await mediaReader.readMetadata())
                  await mediaReader.readSha256(m.uri),
              }
            : <String>{};
    String? activeMediaSha;
    bool skippingActiveMedia = false;

    final completer = Completer<void>();

    _incomingSub = session.incomingFrames().listen(
      (frame) {
        try {
          final env = TransferEnvelope.fromBytes(frame);
          switch (env) {
            case ManifestEnvelope():
              // Already handled at the WaitingForSourceScreen step; ignore
              // a duplicate here.
              break;
            case SmsRecordEnvelope(:final record):
              if (SmsDedup.isDuplicate(smsIndex, record)) {
                _skippedByCategory[DataCategory.sms] =
                    (_skippedByCategory[DataCategory.sms] ?? 0) + 1;
              } else {
                pendingSmsWrites.add(record);
              }
              _processed[DataCategory.sms] =
                  (_processed[DataCategory.sms] ?? 0) + 1;
              if (mounted) setState(() {});
              break;
            case CallLogRecordEnvelope(:final record):
              if (CallLogDedup.isDuplicate(callLogIndex, record)) {
                _skippedByCategory[DataCategory.callLog] =
                    (_skippedByCategory[DataCategory.callLog] ?? 0) + 1;
              } else {
                pendingCallLogWrites.add(record);
              }
              _processed[DataCategory.callLog] =
                  (_processed[DataCategory.callLog] ?? 0) + 1;
              if (mounted) setState(() {});
              break;
            case ContactRecordEnvelope(:final record):
              final keys = ContactsDedup.matchKeysFor(record);
              final isDup = keys.isNotEmpty &&
                  contactsKeys.any((existing) =>
                      existing.intersection(keys).length == keys.length);
              if (isDup) {
                _skippedByCategory[DataCategory.contacts] =
                    (_skippedByCategory[DataCategory.contacts] ?? 0) + 1;
              } else {
                pendingContactWrites.add(record);
              }
              _processed[DataCategory.contacts] =
                  (_processed[DataCategory.contacts] ?? 0) + 1;
              if (mounted) setState(() {});
              break;
            case CalendarEventEnvelope(:final record):
              if (CalendarDedup.isDuplicate(calendarIndex, record)) {
                _skippedByCategory[DataCategory.calendar] =
                    (_skippedByCategory[DataCategory.calendar] ?? 0) + 1;
              } else {
                pendingCalendarWrites.add(record);
              }
              _processed[DataCategory.calendar] =
                  (_processed[DataCategory.calendar] ?? 0) + 1;
              if (mounted) setState(() {});
              break;
            case MediaStartEnvelope(:final header):
              activeMediaSha = header.sha256;
              if (localMediaShas.contains(header.sha256)) {
                skippingActiveMedia = true;
              } else {
                skippingActiveMedia = false;
                // Open the receiver-side MediaStore stream. If insert
                // fails (rare; e.g. storage full), fall back to skipping
                // — the chunks still come in and just get discarded.
                mediaReader
                    .writeStart(
                  sha256: header.sha256,
                  fileName: header.fileName,
                  mimeType: header.mimeType,
                  kind: header.kind,
                  takenAtMs: header.takenAtMs,
                )
                    .then((opened) {
                  if (!opened) {
                    skippingActiveMedia = true;
                  }
                });
              }
              break;
            case MediaChunkEnvelope(
                  :final sha256,
                  :final base64Bytes,
                ):
              if (sha256 != activeMediaSha) break;
              if (skippingActiveMedia) break;
              final bytes = base64.decode(base64Bytes);
              mediaReader.writeChunk(sha256, bytes);
              break;
            case MediaEndEnvelope(:final sha256):
              if (sha256 == activeMediaSha) {
                if (skippingActiveMedia) {
                  _skippedByCategory[DataCategory.photos] =
                      (_skippedByCategory[DataCategory.photos] ?? 0) + 1;
                } else {
                  // Close the stream + clear IS_PENDING. Once this resolves
                  // the file is visible to the gallery.
                  mediaReader.writeEnd(sha256).then((ok) {
                    if (ok) {
                      _writtenByCategory[DataCategory.photos] =
                          (_writtenByCategory[DataCategory.photos] ?? 0) + 1;
                      // Add to local dedup set so a re-streamed copy in
                      // the same session doesn't double-write.
                      localMediaShas.add(sha256);
                    } else {
                      _skippedByCategory[DataCategory.photos] =
                          (_skippedByCategory[DataCategory.photos] ?? 0) +
                              1;
                    }
                    if (mounted) setState(() {});
                  });
                }
                _processed[DataCategory.photos] =
                    (_processed[DataCategory.photos] ?? 0) + 1;
                activeMediaSha = null;
                if (mounted) setState(() {});
              }
              break;
            case CategoryDoneEnvelope(:final category):
              switch (category) {
                case DataCategory.sms:
                  // SMS write is gated on becoming the default SMS app.
                  // Keep the listener alive and handle the role-grab +
                  // write asynchronously; the rest of the protocol
                  // continues in parallel for other categories.
                  _flushSmsBatchAsync(pendingSmsWrites);
                  break;
                case DataCategory.callLog:
                  _flushBatch<CallLogRecord>(
                    pending: pendingCallLogWrites,
                    write: CallLogReader().writeAll,
                    category: DataCategory.callLog,
                  );
                  break;
                case DataCategory.contacts:
                  _flushBatch<Contact>(
                    pending: pendingContactWrites,
                    write: ContactsReader().writeAll,
                    category: DataCategory.contacts,
                  );
                  break;
                case DataCategory.calendar:
                  _flushBatch<CalendarEvent>(
                    pending: pendingCalendarWrites,
                    write: CalendarReader().writeAll,
                    category: DataCategory.calendar,
                  );
                  break;
                case DataCategory.photos:
                  // No writer wired yet.
                  break;
              }
              break;
            case TransferDoneEnvelope():
              if (!completer.isCompleted) completer.complete();
              break;
          }
        } catch (e) {
          if (!completer.isCompleted) completer.completeError(e);
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.completeError(StateError('Peer disconnected'));
        }
      },
    );

    await completer.future;
  }

  /// Flush the SMS batch via the default-SMS-app role grab dance:
  /// 1) Confirm we still have at least one record to write — otherwise skip
  ///    the role intrusion entirely.
  /// 2) Request the role; the system shows a "Set as default SMS app"
  ///    dialog. If the user denies, we mark all pending as skipped and
  ///    move on (transfer continues for the other categories).
  /// 3) Write the records via SmsReader.writeAll. The Done screen will
  ///    surface the previous-default-package so the user knows which app
  ///    to open to switch back.
  Future<void> _flushSmsBatchAsync(List<SmsRecord> pending) async {
    if (pending.isEmpty) return;
    final batch = List<SmsRecord>.from(pending);
    pending.clear();
    final reader = SmsReader();
    final previousDefault = await reader.getDefaultSmsPackage();
    final granted =
        await reader.isDefaultSmsApp() || await reader.requestSmsRole();
    if (!granted) {
      _skippedByCategory[DataCategory.sms] =
          (_skippedByCategory[DataCategory.sms] ?? 0) + batch.length;
      if (mounted) setState(() {});
      return;
    }
    try {
      final written = await reader.writeAll(batch);
      _writtenByCategory[DataCategory.sms] =
          (_writtenByCategory[DataCategory.sms] ?? 0) + written;
      // Stash the previous default so the Done screen can tell the user
      // which app to open to take the role back.
      if (mounted && previousDefault != null) {
        ref
            .read(transferStateProvider.notifier)
            .setPreviousSmsAppPackage(previousDefault);
      }
    } catch (_) {
      // If the write fails wholesale, treat the batch as skipped.
      _skippedByCategory[DataCategory.sms] =
          (_skippedByCategory[DataCategory.sms] ?? 0) + batch.length;
    }
    if (mounted) setState(() {});
  }

  // -------------------------------------------------------- Per-cat flush

  void _flushBatch<T>({
    required List<T> pending,
    required Future<int> Function(List<T>) write,
    required DataCategory category,
  }) {
    if (pending.isEmpty) return;
    final batch = List<T>.from(pending);
    pending.clear();
    write(batch).then((written) {
      _writtenByCategory[category] =
          (_writtenByCategory[category] ?? 0) + written;
      if (mounted) setState(() {});
    });
  }

  // ----------------------------------------------------------------- Render

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(transferStateProvider);
    final manifest = state.senderManifest;
    if (manifest == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Transferring')),
        body: const Center(child: Text('Nothing to transfer.')),
      );
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Transfer failed')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline,
                  size: 56, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 16),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => context.go('/'),
                child: const Text('Start over'),
              ),
            ],
          ),
        ),
      );
    }

    final isReceiver = state.role == DeviceRole.receiver;

    return Scaffold(
      appBar: AppBar(
        title: Text(isReceiver ? 'Receiving' : 'Sending'),
        automaticallyImplyLeading: false,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            for (final c in manifest.categories) _categoryRow(manifest, c),
            const Spacer(),
            if (_done)
              const Center(child: Text('Done — finalizing…'))
            else
              const Center(
                child: Text('Working…',
                    style: TextStyle(fontStyle: FontStyle.italic)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _categoryRow(TransferManifest manifest, DataCategory c) {
    final total = manifest.counts[c] ?? 0;
    final done = _processed[c] ?? 0;
    final progress = total == 0 ? 1.0 : (done / total).clamp(0.0, 1.0);
    final role = ref.read(transferStateProvider).role;
    final isReceiver = role == DeviceRole.receiver;
    // All five categories have writers as of v0.7; receiver always shows
    // the new/duplicate breakdown.
    final detail = isReceiver
        ? '$done / $total received '
            '(${_writtenByCategory[c] ?? 0} new, '
            '${_skippedByCategory[c] ?? 0} duplicates)'
        : '$done / $total';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(_iconFor(c), size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(_labelFor(c))),
              Text(detail,
                  style: const TextStyle(
                    fontFeatures: [FontFeature.tabularFigures()],
                  )),
            ],
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: progress),
        ],
      ),
    );
  }

  IconData _iconFor(DataCategory c) {
    switch (c) {
      case DataCategory.sms:
        return Icons.sms_outlined;
      case DataCategory.callLog:
        return Icons.call_outlined;
      case DataCategory.contacts:
        return Icons.person_outline;
      case DataCategory.photos:
        return Icons.photo_library_outlined;
      case DataCategory.calendar:
        return Icons.calendar_today_outlined;
    }
  }

  String _labelFor(DataCategory c) {
    switch (c) {
      case DataCategory.sms:
        return 'SMS / MMS';
      case DataCategory.callLog:
        return 'Call log';
      case DataCategory.contacts:
        return 'Contacts';
      case DataCategory.photos:
        return 'Photos & videos';
      case DataCategory.calendar:
        return 'Calendar';
    }
  }
}

