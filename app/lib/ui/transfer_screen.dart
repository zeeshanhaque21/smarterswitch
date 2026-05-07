import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/dedup/calendar_dedup.dart';
import '../core/dedup/call_log_dedup.dart';
import '../core/dedup/contacts_dedup.dart';
import '../core/dedup/sms_dedup.dart';
import '../core/model/calendar_event.dart';
import '../core/model/call_log_record.dart';
import '../core/model/contact.dart';
import '../core/model/media_record.dart';
import '../core/model/sms_record.dart';
import '../core/transfer/manifest.dart';
import '../core/transfer/photo_hash_cache.dart';
import '../core/transfer/transport.dart';
import '../platform/calendar_reader.dart';
import '../platform/call_log_reader.dart';
import '../platform/category_counts.dart';
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
/// Per-category lifecycle on the sender. Each row in the Transfer screen
/// renders its status from this. Receiver-side a simpler "active vs done"
/// distinction is drawn from `_processed[c]` against `manifest.counts[c]`.
enum _CategoryPhase {
  /// Not yet reached in the sender's iteration order.
  queued,

  /// Reading metadata / hashing — for photos this is the long pre-flight
  /// hash pass; for other categories it's the brief platform-channel
  /// readAll() call.
  preparing,

  /// Streaming records over the wire.
  streaming,

  /// All records of this category have been sent (sender) or written
  /// (receiver).
  done,
}

class TransferScreen extends ConsumerStatefulWidget {
  const TransferScreen({super.key});

  @override
  ConsumerState<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends ConsumerState<TransferScreen> {
  /// Per-category running tally of items *processed* on this side. On the
  /// sender, "processed" = confirmed by the receiver's ack. On the receiver,
  /// "processed" = received + dedup-decided + (if new) written.
  final Map<DataCategory, int> _processed = {};
  final Map<DataCategory, int> _writtenByCategory = {};
  final Map<DataCategory, int> _skippedByCategory = {};

  /// Per-category count of records the sender has transmitted. The sender
  /// waits until _processed[c] (from receiver acks) reaches _sent[c] before
  /// marking the category done, keeping both progress bars in sync.
  final Map<DataCategory, int> _sent = {};

  /// Per-category lifecycle state — what phase each row is in. Drives the
  /// status label and color in the per-row UI so the user can see at a
  /// glance which category is being prepared/streamed/done.
  final Map<DataCategory, _CategoryPhase> _phase = {};
  bool _done = false;
  String? _error;
  StreamSubscription? _incomingSub;
  final _foreground = ForegroundService();

  /// Number of photos sender has hashed pre-flight. Surfaced as the
  /// "Hashing N / total" line during the pre-flight pass.
  int _hashed = 0;
  int _hashTotal = 0;

  /// Number of photos the receiver said to skip via PhotoSkipListEnvelope.
  /// Used in Done-screen reporting and the progress label so the user
  /// understands why the byte total is less than what they have.
  int _photosSkippedPreflight = 0;

  /// Diagnostics: total frames seen by this device's incoming listener,
  /// last envelope kind decoded, and last error from the listener.
  /// Surfaced on-screen so a user can tell at a glance whether frames
  /// are even reaching this phone.
  int _framesSeen = 0;
  String _lastFrameKind = '—';
  String? _frameError;

  /// Debug: tracks where in the flow we are.
  String _flowState = 'init';

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

  /// Incoming envelopes from receiver (batch acks, category acks, etc.)
  final _receiverAcks = <TransferEnvelope>[];

  Future<void> _runAsSender(
    PairedSession session,
    TransferManifest manifest,
  ) async {
    if (mounted) setState(() => _flowState = 'waiting for Resume');

    // Wait for receiver's Resume (confirms listener is attached).
    final resumeCompleter = Completer<void>();
    final sub = session.incomingFrames().listen((frame) {
      _framesSeen += 1;
      try {
        final env = TransferEnvelope.fromBytes(frame);
        _lastFrameKind = env.runtimeType.toString();
        _receiverAcks.add(env);
        if (env is ResumeEnvelope && !resumeCompleter.isCompleted) {
          resumeCompleter.complete();
        }
      } catch (e) {
        _frameError = e.toString();
      }
      if (mounted) setState(() {});
    });

    try {
      try {
        await resumeCompleter.future.timeout(const Duration(seconds: 120));
      } on TimeoutException {
        throw StateError(
          'The other phone never confirmed it was ready to receive. '
          'Make sure it has tapped "Accept and start transfer" on the '
          'Review screen, then try again.',
        );
      }
      if (mounted) setState(() => _flowState = 'Resume received, sending Ready');

      // Tell receiver we're about to start sending
      await session.sendFrame(const ReadyEnvelope().toBytes());

      for (final c in manifest.categories) {
        _phase[c] = _CategoryPhase.queued;
      }
      if (mounted) setState(() {});

      await _runSenderInner(session, manifest);
      if (mounted) setState(() => _flowState = 'all sent');
    } finally {
      await sub.cancel();
    }
  }

  /// Wait for a specific envelope type from the receiver, with timeout.
  Future<T> _waitForEnvelope<T extends TransferEnvelope>({
    Duration timeout = const Duration(seconds: 60),
    bool Function(T)? where,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      // Check already-received acks
      for (var i = 0; i < _receiverAcks.length; i++) {
        final env = _receiverAcks[i];
        if (env is T && (where == null || where(env))) {
          _receiverAcks.removeAt(i);
          return env;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException('Timed out waiting for ${T.toString()}', timeout);
  }

  Future<void> _runSenderInner(
    PairedSession session,
    TransferManifest manifest,
  ) async {
    for (final category in manifest.categories) {
      _phase[category] = _CategoryPhase.preparing;
      if (mounted) setState(() => _flowState = 'preparing $category');

      final count = manifest.counts[category] ?? 0;

      // 1. Announce category
      await session.sendFrame(CategoryAnnounceEnvelope(
        category: category,
        itemCount: count,
      ).toBytes());
      if (mounted) setState(() => _flowState = 'waiting for ack: $category');

      // 2. Wait for receiver's ack
      await _waitForEnvelope<CategoryAckEnvelope>(
        timeout: const Duration(seconds: 30),
        where: (ack) => ack.category == category,
      );
      if (mounted) setState(() => _flowState = 'streaming $category');

      // 3. Stream records, tracking IDs
      final sentIds = <String>[];

      Future<void> streamWithIds<T>(
        Future<List<T>> Function() reader,
        Uint8List Function(T) encode,
        String Function(T) computeId,
      ) async {
        final records = await reader();
        _phase[category] = _CategoryPhase.streaming;
        if (mounted) setState(() {});
        for (var i = 0; i < records.length; i++) {
          final r = records[i];
          final id = computeId(r);
          sentIds.add(id);
          await session.sendFrame(encode(r));
          _sent[category] = i + 1;
          if (mounted) setState(() {});
        }
      }

      switch (category) {
        case DataCategory.sms:
          await streamWithIds<SmsRecord>(
            () => SmsReader().readAll(),
            (r) {
              final id = SmsDedup.keyFor(r).toString();
              return SmsRecordEnvelope(r, id: id).toBytes();
            },
            (r) => SmsDedup.keyFor(r).toString(),
          );
          break;
        case DataCategory.callLog:
          await streamWithIds<CallLogRecord>(
            () => CallLogReader().readAll(),
            (r) {
              final id = CallLogDedup.keyFor(r).toString();
              return CallLogRecordEnvelope(r, id: id).toBytes();
            },
            (r) => CallLogDedup.keyFor(r).toString(),
          );
          break;
        case DataCategory.contacts:
          await streamWithIds<Contact>(
            () async => (await ContactsReader().readAll())
                .where((c) => !c.isGoogleSynced)
                .toList(growable: false),
            (r) => ContactRecordEnvelope(r).toBytes(),
            (r) => ContactsDedup.matchKeysFor(r).join('|'),
          );
          break;
        case DataCategory.calendar:
          await streamWithIds<CalendarEvent>(
            () => CalendarReader().readAll(),
            (r) => CalendarEventEnvelope(r).toBytes(),
            (r) => CalendarDedup.keyFor(r).toString(),
          );
          break;
        case DataCategory.photos:
          await _streamPhotos(session, () {
            _processed[category] = (_processed[category] ?? 0) + 1;
            if (mounted) setState(() {});
          });
          break;
      }

      // 4. Send CategorySent with all IDs
      if (mounted) setState(() => _flowState = 'waiting for $category confirm');
      await session.sendFrame(CategorySentEnvelope(
        category: category,
        itemIds: sentIds,
      ).toBytes());

      // 5. Wait for CategoryReceived confirmation
      final received = await _waitForEnvelope<CategoryReceivedEnvelope>(
        timeout: const Duration(seconds: 60),
        where: (r) => r.category == category,
      );

      // Update final count from receiver's confirmation
      _processed[category] = received.receivedCount;
      _phase[category] = _CategoryPhase.done;
      if (mounted) setState(() {});
    }

    await session.sendFrame(const TransferDoneEnvelope().toBytes());
  }

  Future<void> _streamPhotos(
    PairedSession session,
    void Function() onFileDone,
  ) async {
    final reader = MediaReader();
    final files = await reader.readMetadata();
    if (mounted) setState(() => _hashTotal = files.length);

    // Open the persistent hash cache. Per-file cache hit = no bytes read
    // for that file → near-instant pre-flight on subsequent transfers
    // when the library is unchanged.
    final cacheDir = (await getApplicationSupportDirectory()).path;
    final cache = await PhotoHashCache.open(cacheDir);

    // (Heartbeat is now global to the whole sender lifetime — see
    // _runAsSender. No need to start a photos-specific one here.)

    // Pre-flight pass: hash every photo before any bytes go out, so we can
    // ask the receiver which it already has. The hash pass is the long
    // pole on a 30k-photo library (~2 minutes on first run, near-instant
    // on subsequent runs when the cache is warm).
    final hashed = <String, MediaMetadata>{};
    final pHashBySha = <String, int>{};
    final liveUris = <String>{};
    try {
      for (final f in files) {
        liveUris.add(f.uri);
        try {
          // Cache lookup: hit iff URI known AND (byteSize, modifiedAtMs)
          // match. Cache miss → compute via the platform channels.
          final cached = cache.get(
            f.uri,
            byteSize: f.byteSize,
            modifiedAtMs: f.modifiedAtMs,
          );
          final String sha;
          int? ph;
          if (cached != null) {
            sha = cached.sha256;
            ph = cached.pHash;
          } else {
            sha = await reader.readSha256(f.uri);
            if (f.kind == MediaKind.image) {
              ph = await reader.computePHash(f.uri);
            }
            cache.put(
              f.uri,
              byteSize: f.byteSize,
              modifiedAtMs: f.modifiedAtMs,
              sha256: sha,
              pHash: ph,
            );
          }
          if (!hashed.containsKey(sha)) {
            hashed[sha] = f;
            if (ph != null) pHashBySha[sha] = ph;
          }
          _hashed += 1;
          if (mounted) setState(() {});
        } catch (_) {
          // File became unreadable (deleted, permission revoked) — skip.
        }
      }
      // Drop cache entries for files no longer on the device. Keeps the
      // cache file from growing unboundedly across years of use.
      cache.retainOnly(liveUris);
      await cache.save();
    } catch (_) {
      // Honest fallthrough — the global heartbeat ticker is independent
      // of the hashing pass, so leaving exception handling lighter here
      // is fine.
    }

    // Hashing complete; flip the row to streaming so the user sees the
    // phase change.
    _phase[DataCategory.photos] = _CategoryPhase.streaming;
    if (mounted) setState(() {});

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

  /// Pending dedup/write futures for parallel processing.
  final _pendingDedupFutures = <Future<void>>[];

  /// Per-category buffer of incoming records and their IDs.
  final _receivedIds = <DataCategory, List<String>>{};

  Future<void> _runAsReceiver(
    PairedSession session,
    TransferManifest manifest,
  ) async {
    setState(() => _flowState = 'perms');

    // Step 1: Request permissions needed to write data later.
    final neededPermissions = <Permission>{
      for (final c in manifest.categories) ...permissionsFor(c),
    };
    for (final p in neededPermissions) {
      try {
        await p.request();
      } catch (_) {}
    }
    if (mounted) setState(() => _flowState = 'perms done');

    // Buffers to collect all incoming records during transfer.
    final incomingSms = <SmsRecord>[];
    final incomingCallLog = <CallLogRecord>[];
    final incomingContacts = <Contact>[];
    final incomingCalendar = <CalendarEvent>[];

    // Track current category being received (used for debugging)
    // ignore: unused_local_variable
    DataCategory? activeCategory;

    // Photos still use streaming write (too large to buffer).
    final mediaReader = MediaReader();
    final localMediaShas = <String>{};
    String? activeMediaSha;
    bool skippingActiveMedia = false;

    final completer = Completer<void>();
    final readyCompleter = Completer<void>();
    if (mounted) setState(() => _flowState = 'attaching listener');

    // Step 2: Attach listener and tell sender we're ready.
    _incomingSub = session.incomingFrames().listen(
      (frame) {
        _framesSeen += 1;
        try {
          final env = TransferEnvelope.fromBytes(frame);
          _lastFrameKind = env.runtimeType.toString();
          switch (env) {
            case ManifestEnvelope():
              break;

            // New protocol: CategoryAnnounce starts a category
            case CategoryAnnounceEnvelope(:final category, :final itemCount):
              activeCategory = category;
              _receivedIds[category] = [];
              _phase[category] = _CategoryPhase.streaming;
              if (mounted) setState(() => _flowState = 'receiving $category ($itemCount items)');
              // Schedule ack in separate event loop iteration to not interfere with socket reads
              Timer.run(() {
                session.sendFrame(CategoryAckEnvelope(category: category).toBytes())
                    .catchError((Object _) {});
              });
              break;

            // Buffer records - use ID from envelope if present
            case SmsRecordEnvelope(:final record, :final id):
              incomingSms.add(record);
              if (id != null) {
                _receivedIds[DataCategory.sms] ??= [];
                _receivedIds[DataCategory.sms]!.add(id);
              }
              _processed[DataCategory.sms] =
                  (_processed[DataCategory.sms] ?? 0) + 1;
              if (mounted) setState(() {});
              break;

            case CallLogRecordEnvelope(:final record, :final id):
              incomingCallLog.add(record);
              if (id != null) {
                _receivedIds[DataCategory.callLog] ??= [];
                _receivedIds[DataCategory.callLog]!.add(id);
              }
              _processed[DataCategory.callLog] =
                  (_processed[DataCategory.callLog] ?? 0) + 1;
              if (mounted) setState(() {});
              break;

            case ContactRecordEnvelope(:final record):
              incomingContacts.add(record);
              _processed[DataCategory.contacts] =
                  (_processed[DataCategory.contacts] ?? 0) + 1;
              if (mounted) setState(() {});
              break;

            case CalendarEventEnvelope(:final record):
              incomingCalendar.add(record);
              _processed[DataCategory.calendar] =
                  (_processed[DataCategory.calendar] ?? 0) + 1;
              if (mounted) setState(() {});
              break;

            // New protocol: CategorySent ends a category
            case CategorySentEnvelope(:final category, :final itemIds):
              final received = _receivedIds[category] ?? [];
              final missing = itemIds.where((id) => !received.contains(id)).toList();
              // Schedule confirmation in separate event loop iteration
              Timer.run(() {
                session.sendFrame(CategoryReceivedEnvelope(
                  category: category,
                  receivedCount: received.length,
                  missingIds: missing,
                ).toBytes()).catchError((Object _) {});
              });
              _phase[category] = _CategoryPhase.done;
              if (mounted) setState(() => _flowState = '$category done, deduping in background');
              // Start background dedup/write for this category
              _pendingDedupFutures.add(_dedupAndWriteCategory(
                category,
                incomingSms: List.of(incomingSms),
                incomingCallLog: List.of(incomingCallLog),
                incomingContacts: List.of(incomingContacts),
                incomingCalendar: List.of(incomingCalendar),
              ));
              // Clear buffers for next category
              if (category == DataCategory.sms) incomingSms.clear();
              if (category == DataCategory.callLog) incomingCallLog.clear();
              if (category == DataCategory.contacts) incomingContacts.clear();
              if (category == DataCategory.calendar) incomingCalendar.clear();
              break;

            case PhotoHashesEnvelope(:final entries):
              final skip = <String>[];
              for (final e in entries) {
                if (localMediaShas.contains(e.sha256)) {
                  skip.add(e.sha256);
                }
              }
              // Schedule in separate event loop iteration
              Timer.run(() {
                session.sendFrame(PhotoSkipListEnvelope(skip: skip).toBytes())
                    .catchError((Object _) {});
              });
              if (mounted) setState(() {});
              break;
            case PhotoSkipListEnvelope():
              break;
            case MediaStartEnvelope(:final header):
              activeMediaSha = header.sha256;
              if (localMediaShas.contains(header.sha256)) {
                skippingActiveMedia = true;
              } else {
                skippingActiveMedia = false;
                mediaReader
                    .writeStart(
                  sha256: header.sha256,
                  fileName: header.fileName,
                  mimeType: header.mimeType,
                  kind: header.kind,
                  takenAtMs: header.takenAtMs,
                )
                    .then((opened) {
                  if (!opened) skippingActiveMedia = true;
                });
              }
              break;
            case MediaChunkEnvelope(:final sha256, :final base64Bytes):
              if (sha256 != activeMediaSha || skippingActiveMedia) break;
              mediaReader.writeChunk(sha256, base64.decode(base64Bytes));
              break;
            case MediaEndEnvelope(:final sha256):
              if (sha256 == activeMediaSha) {
                if (skippingActiveMedia) {
                  _skippedByCategory[DataCategory.photos] =
                      (_skippedByCategory[DataCategory.photos] ?? 0) + 1;
                } else {
                  mediaReader.writeEnd(sha256).then((ok) {
                    if (ok) {
                      _writtenByCategory[DataCategory.photos] =
                          (_writtenByCategory[DataCategory.photos] ?? 0) + 1;
                      localMediaShas.add(sha256);
                    } else {
                      _skippedByCategory[DataCategory.photos] =
                          (_skippedByCategory[DataCategory.photos] ?? 0) + 1;
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

            // Legacy envelope (keep for back-compat)
            case CategoryDoneEnvelope(:final category):
              _phase[category] = _CategoryPhase.done;
              if (mounted) setState(() {});
              break;

            case TransferDoneEnvelope():
              if (!completer.isCompleted) completer.complete();
              break;
            case ResumeEnvelope():
              break;
            case HeartbeatEnvelope():
              break;
            case ReadyEnvelope():
              if (!readyCompleter.isCompleted) readyCompleter.complete();
              break;
            case RecordAckEnvelope():
              break;
            case CategoryAckEnvelope():
              break;
            case CategoryReceivedEnvelope():
              break;
            case ItemBatchAckEnvelope():
              break;
          }
        } catch (e) {
          _frameError = e.toString();
          if (!completer.isCompleted) completer.completeError(e);
        }
        if (mounted) setState(() {});
      },
      onError: (Object e) {
        _frameError = e.toString();
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.completeError(StateError('Peer disconnected'));
        }
      },
    );

    // Tell sender we're ready.
    if (mounted) setState(() => _flowState = 'sending Resume');
    try {
      await session.sendFrame(ResumeEnvelope(watermarks: const {}).toBytes());
    } catch (_) {}

    // Wait for sender's Ready acknowledgment (handled in main listener).
    if (mounted) setState(() => _flowState = 'waiting for Ready');
    await readyCompleter.future.timeout(const Duration(seconds: 30)).catchError((_) {});

    // Wait for all data to arrive.
    if (mounted) setState(() => _flowState = 'waiting for data');
    await completer.future;
    if (mounted) setState(() => _flowState = 'data received');

    // Wait for all background dedup tasks to complete
    if (mounted) setState(() => _flowState = 'finalizing writes');
    await Future.wait(_pendingDedupFutures);
    if (mounted) setState(() => _flowState = 'all done');
  }

  /// Background dedup and write for a single category.
  Future<void> _dedupAndWriteCategory(
    DataCategory category, {
    required List<SmsRecord> incomingSms,
    required List<CallLogRecord> incomingCallLog,
    required List<Contact> incomingContacts,
    required List<CalendarEvent> incomingCalendar,
  }) async {
    switch (category) {
      case DataCategory.sms:
        if (incomingSms.isEmpty) return;
        final smsIndex = SmsDedup.indexOf(await SmsReader().readAll());
        final toWrite = <SmsRecord>[];
        for (final r in incomingSms) {
          if (SmsDedup.isDuplicate(smsIndex, r)) {
            _skippedByCategory[DataCategory.sms] =
                (_skippedByCategory[DataCategory.sms] ?? 0) + 1;
          } else {
            toWrite.add(r);
          }
        }
        if (toWrite.isNotEmpty) {
          final reader = SmsReader();
          final granted =
              await reader.isDefaultSmsApp() || await reader.requestSmsRole();
          if (granted) {
            final written = await reader.writeAll(toWrite);
            _writtenByCategory[DataCategory.sms] =
                (_writtenByCategory[DataCategory.sms] ?? 0) + written;
          } else {
            _skippedByCategory[DataCategory.sms] =
                (_skippedByCategory[DataCategory.sms] ?? 0) + toWrite.length;
          }
        }
        if (mounted) setState(() {});
        break;

      case DataCategory.callLog:
        if (incomingCallLog.isEmpty) return;
        final callLogIndex = CallLogDedup.indexOf(await CallLogReader().readAll());
        final toWrite = <CallLogRecord>[];
        for (final r in incomingCallLog) {
          if (CallLogDedup.isDuplicate(callLogIndex, r)) {
            _skippedByCategory[DataCategory.callLog] =
                (_skippedByCategory[DataCategory.callLog] ?? 0) + 1;
          } else {
            toWrite.add(r);
          }
        }
        if (toWrite.isNotEmpty) {
          final written = await CallLogReader().writeAll(toWrite);
          _writtenByCategory[DataCategory.callLog] =
              (_writtenByCategory[DataCategory.callLog] ?? 0) + written;
        }
        if (mounted) setState(() {});
        break;

      case DataCategory.contacts:
        if (incomingContacts.isEmpty) return;
        final contactsKeys = <Set<String>>[
          for (final c in await ContactsReader().readAll())
            ContactsDedup.matchKeysFor(c),
        ];
        final toWrite = <Contact>[];
        for (final r in incomingContacts) {
          final keys = ContactsDedup.matchKeysFor(r);
          final isDup = keys.isNotEmpty &&
              contactsKeys.any(
                  (existing) => existing.intersection(keys).length == keys.length);
          if (isDup) {
            _skippedByCategory[DataCategory.contacts] =
                (_skippedByCategory[DataCategory.contacts] ?? 0) + 1;
          } else {
            toWrite.add(r);
          }
        }
        if (toWrite.isNotEmpty) {
          final written = await ContactsReader().writeAll(toWrite);
          _writtenByCategory[DataCategory.contacts] =
              (_writtenByCategory[DataCategory.contacts] ?? 0) + written;
        }
        if (mounted) setState(() {});
        break;

      case DataCategory.calendar:
        if (incomingCalendar.isEmpty) return;
        final calendarIndex = CalendarDedup.indexOf(await CalendarReader().readAll());
        final toWrite = <CalendarEvent>[];
        for (final r in incomingCalendar) {
          if (CalendarDedup.isDuplicate(calendarIndex, r)) {
            _skippedByCategory[DataCategory.calendar] =
                (_skippedByCategory[DataCategory.calendar] ?? 0) + 1;
          } else {
            toWrite.add(r);
          }
        }
        if (toWrite.isNotEmpty) {
          final written = await CalendarReader().writeAll(toWrite);
          _writtenByCategory[DataCategory.calendar] =
              (_writtenByCategory[DataCategory.calendar] ?? 0) + written;
        }
        if (mounted) setState(() {});
        break;

      case DataCategory.photos:
        // Photos use streaming write, handled inline
        break;
    }
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
            // Diagnostic strip at top so it's always visible
            Container(
              padding: const EdgeInsets.all(8),
              color: Colors.grey.shade200,
              child: DefaultTextStyle.merge(
                style: const TextStyle(fontSize: 11, color: Colors.black87),
                child: Column(
                  children: [
                    Text('state: $_flowState | frames: $_framesSeen'),
                    Text('last: $_lastFrameKind${_frameError != null ? " | err: $_frameError" : ""}'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (_isHashingPhase(state)) _hashingBanner(),
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

  /// True when the sender is in the photo pre-flight hashing pass and
  /// hasn't started streaming chunks yet. Drives the prominent
  /// hashing-progress banner.
  bool _isHashingPhase(TransferState state) {
    if (state.role != DeviceRole.sender) return false;
    if (_hashTotal == 0) return false;
    return _hashed < _hashTotal;
  }

  Widget _hashingBanner() {
    final theme = Theme.of(context);
    final pct = _hashTotal == 0 ? 0.0 : _hashed / _hashTotal;
    return Card(
      color: theme.colorScheme.primaryContainer,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Preparing photos',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Hashing $_hashed / $_hashTotal — first run only; future '
              'transfers reuse this work.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: pct.clamp(0.0, 1.0)),
          ],
        ),
      ),
    );
  }

  Widget _categoryRow(TransferManifest manifest, DataCategory c) {
    final total = manifest.counts[c] ?? 0;
    final role = ref.read(transferStateProvider).role;
    final isReceiver = role == DeviceRole.receiver;
    // Sender shows _sent (what it transmitted); receiver shows _processed.
    final done = isReceiver ? (_processed[c] ?? 0) : (_sent[c] ?? 0);
    final phase = _phase[c] ??
        (isReceiver
            // Receiver: derived from progress vs total because the
            // receiver doesn't run the queued/preparing/streaming
            // state machine — it just listens.
            ? (done == 0 && total > 0
                ? _CategoryPhase.queued
                : (done < total ? _CategoryPhase.streaming : _CategoryPhase.done))
            : _CategoryPhase.queued);

    // Progress bar is the unit-of-work fraction. For sender during the
    // photo hashing pass, that's _hashed/_hashTotal; otherwise done/total.
    final progress = c == DataCategory.photos &&
            !isReceiver &&
            phase == _CategoryPhase.preparing &&
            _hashTotal > 0
        ? (_hashed / _hashTotal).clamp(0.0, 1.0)
        : (total == 0 ? 1.0 : (done / total).clamp(0.0, 1.0));

    final phaseLabel = _phaseLabel(c, phase, isReceiver: isReceiver);
    final phaseColor = _phaseColor(phase);
    final detail = _detailLine(
      c,
      phase,
      total: total,
      done: done,
      isReceiver: isReceiver,
    );

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
              if (phaseLabel != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: phaseColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    phaseLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
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

  String? _phaseLabel(
    DataCategory c,
    _CategoryPhase phase, {
    required bool isReceiver,
  }) {
    switch (phase) {
      case _CategoryPhase.queued:
        return 'Queued';
      case _CategoryPhase.preparing:
        if (c == DataCategory.photos && !isReceiver) return 'Hashing';
        return 'Reading';
      case _CategoryPhase.streaming:
        return null; // Detail line carries the count; chip would be redundant.
      case _CategoryPhase.done:
        return 'Done';
    }
  }

  Color _phaseColor(_CategoryPhase phase) {
    switch (phase) {
      case _CategoryPhase.queued:
        return Colors.grey;
      case _CategoryPhase.preparing:
        return Theme.of(context).colorScheme.primary;
      case _CategoryPhase.streaming:
        return Theme.of(context).colorScheme.primary;
      case _CategoryPhase.done:
        return Colors.green;
    }
  }

  String _detailLine(
    DataCategory c,
    _CategoryPhase phase, {
    required int total,
    required int done,
    required bool isReceiver,
  }) {
    if (c == DataCategory.photos &&
        !isReceiver &&
        phase == _CategoryPhase.preparing) {
      return 'Hashing $_hashed / $_hashTotal';
    }
    if (isReceiver) {
      return '$done / $total received '
          '(${_writtenByCategory[c] ?? 0} new, '
          '${_skippedByCategory[c] ?? 0} duplicates)';
    }
    if (c == DataCategory.photos && _photosSkippedPreflight > 0) {
      return '$done / $total sent '
          '($_photosSkippedPreflight skipped — already on the other phone)';
    }
    return '$done / $total';
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

