import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/dedup/calendar_dedup.dart';
import '../core/dedup/call_log_dedup.dart';
import '../core/dedup/contacts_dedup.dart';
import '../core/dedup/photos_dedup.dart';
import '../core/dedup/sms_dedup.dart';
import '../core/model/calendar_event.dart';
import '../core/model/call_log_record.dart';
import '../core/model/contact.dart';
import '../core/model/media_record.dart';
import '../core/model/sms_record.dart';
import '../core/transfer/manifest.dart';
import '../core/transfer/transport.dart';
import '../core/transfer/wal.dart';
import '../platform/calendar_reader.dart';
import '../platform/call_log_reader.dart';
import '../platform/contacts_reader.dart';
import '../platform/foreground_service.dart';
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
  final _foreground = ForegroundService();

  /// Number of photos sender has hashed pre-flight. Surfaced as the
  /// "Hashing N / total" line during the pre-flight pass.
  int _hashed = 0;

  /// Number of photos the receiver said to skip via PhotoSkipListEnvelope.
  /// Used in Done-screen reporting and the progress label so the user
  /// understands why the byte total is less than what they have.
  int _photosSkippedPreflight = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Notification permission is required on Android 13+ for the
      // foreground service to actually display its ongoing notification.
      // If denied the FGS still runs but headlessly; we proceed either way.
      try {
        await Permission.notification.request();
      } catch (_) {}
      // Hold the OS to the transfer; Android otherwise kills the socket
      // and CPU within seconds of screen-off, so a 30-minute photo
      // migration would die any time the phone screen sleeps.
      await _foreground.start();
      await _start();
    });
  }

  @override
  void dispose() {
    _incomingSub?.cancel();
    _foreground.stop();
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
    // Wait briefly for the receiver's ResumeEnvelope so we can skip records
    // it already wrote in a prior session (Wi-Fi drop / app crash). On
    // first-ever transfer or v0.11-receiver back-compat, no Resume comes —
    // we time out and treat all watermarks as 0 (= "start from the top").
    final skip = await _awaitReceiverResume(session);
    if (skip.values.any((n) => n > 0) && mounted) {
      setState(() {});
    }

    for (final category in manifest.categories) {
      _processed[category] = 0;
      final n = skip[category] ?? 0;
      switch (category) {
        case DataCategory.sms:
          final records = await SmsReader().readAll();
          for (var i = 0; i < records.length; i++) {
            if (i < n) continue;
            await session.sendFrame(SmsRecordEnvelope(records[i]).toBytes());
            _processed[category] = (_processed[category] ?? 0) + 1;
            if (mounted) setState(() {});
          }
          break;
        case DataCategory.callLog:
          final records = await CallLogReader().readAll();
          for (var i = 0; i < records.length; i++) {
            if (i < n) continue;
            await session.sendFrame(CallLogRecordEnvelope(records[i]).toBytes());
            _processed[category] = (_processed[category] ?? 0) + 1;
            if (mounted) setState(() {});
          }
          break;
        case DataCategory.contacts:
          final records = (await ContactsReader().readAll())
              .where((c) => !c.isGoogleSynced)
              .toList(growable: false);
          for (var i = 0; i < records.length; i++) {
            if (i < n) continue;
            await session.sendFrame(ContactRecordEnvelope(records[i]).toBytes());
            _processed[category] = (_processed[category] ?? 0) + 1;
            if (mounted) setState(() {});
          }
          break;
        case DataCategory.calendar:
          final records = await CalendarReader().readAll();
          for (var i = 0; i < records.length; i++) {
            if (i < n) continue;
            await session.sendFrame(CalendarEventEnvelope(records[i]).toBytes());
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

  /// Briefly subscribe to the session's incoming frames and wait for a
  /// ResumeEnvelope. If none arrives within 5s, fall back to "skip nothing"
  /// — the receiver may be a v0.11 build that doesn't send Resume.
  Future<Map<DataCategory, int>> _awaitReceiverResume(
    PairedSession session,
  ) async {
    final completer = Completer<Map<DataCategory, int>>();
    final sub = session.incomingFrames().listen((frame) {
      try {
        final env = TransferEnvelope.fromBytes(frame);
        if (env is ResumeEnvelope && !completer.isCompleted) {
          completer.complete(env.watermarks);
        }
      } catch (_) {/* not for us */}
    });
    try {
      final result =
          await completer.future.timeout(const Duration(seconds: 5));
      return result;
    } on TimeoutException {
      return const {};
    } finally {
      await sub.cancel();
    }
  }

  Future<void> _streamPhotos(
    PairedSession session,
    void Function() onFileDone,
  ) async {
    final reader = MediaReader();
    final files = await reader.readMetadata();

    // Pre-flight pass: hash every photo before any bytes go out, so we can
    // ask the receiver which it already has. The hash pass is the long
    // pole on a 30k-photo library (~2 minutes); progress is exposed to
    // the user via the Hashing column.
    final hashed = <String, MediaMetadata>{};
    final pHashBySha = <String, int>{};
    for (final f in files) {
      try {
        final sha = await reader.readSha256(f.uri);
        if (!hashed.containsKey(sha)) {
          hashed[sha] = f;
          // pHash is best-effort: videos return null, RAW formats return
          // null. Receiver-side fuzzy match treats null pHash as "skip".
          if (f.kind == MediaKind.image) {
            final ph = await reader.computePHash(f.uri);
            if (ph != null) pHashBySha[sha] = ph;
          }
        }
        _hashed += 1;
        if (mounted) setState(() {});
      } catch (_) {
        // File became unreadable (deleted, permission revoked) — skip.
      }
    }

    // Send the hashes; await the receiver's skip list.
    await session.sendFrame(PhotoHashesEnvelope(
      entries: [
        for (final sha in hashed.keys)
          PhotoHashEntry(sha256: sha, pHash: pHashBySha[sha]),
      ],
    ).toBytes());
    final skipSet = <String>{};
    final waitForSkip = Completer<void>();
    final sub = session.incomingFrames().listen((frame) {
      try {
        final env = TransferEnvelope.fromBytes(frame);
        if (env is PhotoSkipListEnvelope) {
          skipSet.addAll(env.skip);
          if (!waitForSkip.isCompleted) waitForSkip.complete();
        }
      } catch (_) {/* not for us */}
    });
    try {
      await waitForSkip.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      // Receiver didn't reply — assume nothing to skip and stream
      // everything (back-compat with v0.7-and-older receivers).
    }
    await sub.cancel();

    _photosSkippedPreflight = skipSet.length;
    if (mounted) setState(() {});

    for (final entry in hashed.entries) {
      final sha = entry.key;
      final f = entry.value;
      if (skipSet.contains(sha)) {
        // Sender side counts the skip too so the per-category progress
        // bar reflects "we've handled this file even though we didn't
        // send bytes."
        onFileDone();
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
    // Per-category WAL: persists the count of records this device has
    // received per category across sessions. After a Wi-Fi drop, the
    // next session reads these watermarks and we ship them to the sender
    // via ResumeEnvelope so it skips records we already have. Photos use
    // sha256-based dedup (the existing pre-flight skip-list) instead of
    // ordinal sequencing — they don't get a WAL.
    final walDir = (await getApplicationSupportDirectory()).path;
    final wals = <DataCategory, CategoryWal>{
      for (final c in manifest.categories
          .where((c) => c != DataCategory.photos))
        c: await CategoryWal.open('$walDir/${c.name}.wal'),
    };
    final receivedByCategory = <DataCategory, int>{
      for (final e in wals.entries) e.key: e.value.watermark,
    };

    // Tell the sender what we already have so it can skip ahead.
    await session.sendFrame(ResumeEnvelope(
      watermarks: {
        for (final e in wals.entries) e.key: e.value.watermark,
      },
    ).toBytes());

    Future<void> ackReceived(DataCategory c) async {
      final next = (receivedByCategory[c] ?? 0) + 1;
      receivedByCategory[c] = next;
      try {
        await wals[c]?.ack(next);
      } catch (_) {/* WAL ack regression — ignore */}
    }

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
    // v0.13: also collect pHashes from the local library so the
    // receiver can surface fuzzy matches (re-encoded copies) on
    // PhotoHashesEnvelope receipt.
    final mediaReader = MediaReader();
    final localMediaShas = <String>{};
    final localMediaPHashes = <int>[];
    if (manifest.categories.contains(DataCategory.photos)) {
      for (final m in await mediaReader.readMetadata()) {
        try {
          localMediaShas.add(await mediaReader.readSha256(m.uri));
          if (m.kind == MediaKind.image) {
            final ph = await mediaReader.computePHash(m.uri);
            if (ph != null) localMediaPHashes.add(ph);
          }
        } catch (_) {/* file disappeared */}
      }
    }
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
              ackReceived(DataCategory.sms);
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
              ackReceived(DataCategory.callLog);
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
              ackReceived(DataCategory.contacts);
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
              ackReceived(DataCategory.calendar);
              if (mounted) setState(() {});
              break;
            case PhotoHashesEnvelope(:final entries):
              // Exact sha256 matches → skip (existing v0.9 behavior).
              final skip = <String>[];
              var fuzzyCount = 0;
              for (final e in entries) {
                if (localMediaShas.contains(e.sha256)) {
                  skip.add(e.sha256);
                  continue;
                }
                // Fuzzy: incoming pHash within threshold of any local
                // pHash. v0.13 auto-resolves these as "keep both" — the
                // sender still streams the file, receiver writes it as a
                // new entry, the user sees the duplicate visually but no
                // data is lost. The mid-transfer conflict-review UI gate
                // is v0.14 work.
                final ph = e.pHash;
                if (ph == null) continue;
                for (final localPh in localMediaPHashes) {
                  if (PhotosDedup.hammingDistance64(ph, localPh) <=
                      PhotosDedup.defaultPhashThreshold) {
                    fuzzyCount += 1;
                    break;
                  }
                }
              }
              if (fuzzyCount > 0) {
                debugPrint(
                  'v0.13 pHash: $fuzzyCount near-match photos auto-'
                  'resolved as Keep Both — full review-screen gate '
                  'lands in v0.14.',
                );
              }
              session
                  .sendFrame(PhotoSkipListEnvelope(skip: skip).toBytes())
                  .catchError((Object _) {});
              _skippedByCategory[DataCategory.photos] =
                  (_skippedByCategory[DataCategory.photos] ?? 0) + skip.length;
              if (mounted) setState(() {});
              break;
            case PhotoSkipListEnvelope():
              // Receiver-side, this should never arrive. Sender-side, the
              // _streamPhotos local subscription consumes it; if we land
              // here it's stray.
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
            case ResumeEnvelope():
              // Receiver-side: never receives Resume (it sends, not consumes).
              // If we land here it's a stray frame — drop it.
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

    // Successful transfer — reset all per-category WALs so the next
    // transfer starts fresh. Mid-transfer drops never reach here, so
    // the next session reads non-zero watermarks and resumes.
    for (final wal in wals.values) {
      try {
        await wal.reset();
        await wal.close();
      } catch (_) {}
    }
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
    final isSenderHashingPhotos =
        !isReceiver && c == DataCategory.photos && _hashed > 0 && done == 0;

    // All five categories have writers as of v0.7; receiver always shows
    // the new/duplicate breakdown. The sender shows a hashing-phase
    // status for photos, then progresses to bytes-sent once chunks flow.
    final detail = isSenderHashingPhotos
        ? 'Hashing $_hashed / $total'
        : isReceiver
            ? '$done / $total received '
                '(${_writtenByCategory[c] ?? 0} new, '
                '${_skippedByCategory[c] ?? 0} duplicates)'
            : c == DataCategory.photos && _photosSkippedPreflight > 0
                ? '$done / $total sent '
                    '($_photosSkippedPreflight skipped — already on the other phone)'
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

