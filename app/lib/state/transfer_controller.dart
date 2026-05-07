import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
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
import 'transfer_progress.dart';
import 'transfer_state.dart';

class TransferParams {
  const TransferParams({
    required this.session,
    required this.manifest,
    required this.role,
  });

  final PairedSession session;
  final TransferManifest manifest;
  final DeviceRole role;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TransferParams &&
          session == other.session &&
          manifest == other.manifest &&
          role == other.role;

  @override
  int get hashCode => Object.hash(session, manifest, role);
}

class TransferController extends StateNotifier<TransferProgress> {
  TransferController(this._session, this._manifest, this._role)
      : super(const TransferProgress());

  final PairedSession _session;
  final TransferManifest _manifest;
  final DeviceRole _role;

  StreamSubscription? _incomingSub;
  Timer? _uiTimer;
  final _foreground = ForegroundService();

  final _receiverAcks = <TransferEnvelope>[];

  Completer<void>? _onDone;

  Future<void> start() async {
    try {
      await _foreground.start();
      if (_role == DeviceRole.sender) {
        await _runAsSender();
      } else {
        await _runAsReceiver();
      }
    } catch (e) {
      state = state.copyWith(error: '$e');
      return;
    }
    state = state.copyWith(done: true);
  }

  @override
  void dispose() {
    _incomingSub?.cancel();
    _uiTimer?.cancel();
    _foreground.stop();
    super.dispose();
  }

  void _update(TransferProgress Function(TransferProgress) updater) {
    state = updater(state);
  }

  void _setFlow(String flowState) {
    _update((s) => s.copyWith(flowState: flowState));
  }

  void _setPhase(DataCategory c, CategoryPhase phase) {
    final phases = Map<DataCategory, CategoryPhase>.from(state.phases);
    phases[c] = phase;
    _update((s) => s.copyWith(phases: phases));
  }

  void _incrementProcessed(DataCategory c) {
    final processed = Map<DataCategory, int>.from(state.processed);
    processed[c] = (processed[c] ?? 0) + 1;
    _update((s) => s.copyWith(processed: processed));
  }

  void _setSent(DataCategory c, int count) {
    final sent = Map<DataCategory, int>.from(state.sent);
    sent[c] = count;
    _update((s) => s.copyWith(sent: sent));
  }

  void _incrementWritten(DataCategory c) {
    final written = Map<DataCategory, int>.from(state.written);
    written[c] = (written[c] ?? 0) + 1;
    _update((s) => s.copyWith(written: written));
  }

  void _incrementSkipped(DataCategory c) {
    final skipped = Map<DataCategory, int>.from(state.skipped);
    skipped[c] = (skipped[c] ?? 0) + 1;
    _update((s) => s.copyWith(skipped: skipped));
  }

  void _onFrame(String kind, {String? error}) {
    _update((s) => s.copyWith(
          framesSeen: s.framesSeen + 1,
          lastFrameKind: kind,
          frameError: error,
        ));
  }

  // ───────────────────────────────────────────────────────────────── Sender

  Future<void> _runAsSender() async {
    debugPrint('[TX] Starting sender');
    _setFlow('waiting for Resume');

    final resumeCompleter = Completer<void>();
    final sub = _session.incomingFrames().listen((frame) {
      try {
        final env = TransferEnvelope.fromBytes(frame);
        debugPrint('[TX] Received: ${env.runtimeType}');
        _onFrame(env.runtimeType.toString());
        _receiverAcks.add(env);
        if (env is ResumeEnvelope && !resumeCompleter.isCompleted) {
          debugPrint('[TX] Resume received');
          resumeCompleter.complete();
        }
      } catch (e) {
        debugPrint('[TX] Frame error: $e');
        _onFrame('error', error: e.toString());
      }
    });

    try {
      debugPrint('[TX] Waiting for Resume...');
      try {
        await resumeCompleter.future.timeout(const Duration(seconds: 120));
      } on TimeoutException {
        throw StateError(
          'The other phone never confirmed it was ready to receive. '
          'Make sure it has tapped "Accept and start transfer" on the '
          'Review screen, then try again.',
        );
      }
      debugPrint('[TX] Sending Ready');
      _setFlow('Resume received, sending Ready');
      await _session.sendFrame(const ReadyEnvelope().toBytes());
      debugPrint('[TX] Ready sent');

      for (final c in _manifest.categories) {
        _setPhase(c, CategoryPhase.queued);
      }

      await _runSenderInner();
      _setFlow('all sent');
    } finally {
      await sub.cancel();
    }
  }

  Future<T> _waitForEnvelope<T extends TransferEnvelope>({
    Duration timeout = const Duration(seconds: 60),
    bool Function(T)? where,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
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

  Future<void> _runSenderInner() async {
    for (final category in _manifest.categories) {
      debugPrint('[TX] Starting category: $category');
      _setPhase(category, CategoryPhase.preparing);
      _setFlow('preparing $category');

      final count = _manifest.counts[category] ?? 0;

      debugPrint('[TX] Sending CategoryAnnounce for $category ($count items)');
      await _session.sendFrame(CategoryAnnounceEnvelope(
        category: category,
        itemCount: count,
      ).toBytes());
      debugPrint('[TX] Waiting for CategoryAck for $category');
      _setFlow('waiting for ack: $category');

      await _waitForEnvelope<CategoryAckEnvelope>(
        timeout: const Duration(seconds: 30),
        where: (ack) => ack.category == category,
      );
      _setFlow('streaming $category');

      final sentIds = <String>[];

      Future<void> streamWithIds<T>(
        Future<List<T>> Function() reader,
        Uint8List Function(T) encode,
        String Function(T) computeId,
      ) async {
        final records = await reader();
        _setPhase(category, CategoryPhase.streaming);
        for (var i = 0; i < records.length; i++) {
          final r = records[i];
          final id = computeId(r);
          sentIds.add(id);
          await _session.sendFrame(encode(r));
          _setSent(category, i + 1);
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
          await _streamPhotos(() {
            _incrementProcessed(category);
          });
          break;
      }

      _setFlow('waiting for $category confirm');
      await _session.sendFrame(CategorySentEnvelope(
        category: category,
        itemIds: sentIds,
      ).toBytes());

      final received = await _waitForEnvelope<CategoryReceivedEnvelope>(
        timeout: const Duration(seconds: 60),
        where: (r) => r.category == category,
      );

      final processed = Map<DataCategory, int>.from(state.processed);
      processed[category] = received.receivedCount;
      _update((s) => s.copyWith(processed: processed));
      _setPhase(category, CategoryPhase.done);
    }

    await _session.sendFrame(const TransferDoneEnvelope().toBytes());
  }

  Future<void> _streamPhotos(void Function() onFileDone) async {
    final reader = MediaReader();
    final files = await reader.readMetadata();
    _update((s) => s.copyWith(hashTotal: files.length));

    final cacheDir = (await getApplicationSupportDirectory()).path;
    final cache = await PhotoHashCache.open(cacheDir);

    final hashed = <String, MediaMetadata>{};
    final pHashBySha = <String, int>{};
    final liveUris = <String>{};

    for (final f in files) {
      liveUris.add(f.uri);
      try {
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
        _update((s) => s.copyWith(hashed: s.hashed + 1));
      } catch (_) {}
    }
    cache.retainOnly(liveUris);
    await cache.save();

    _setPhase(DataCategory.photos, CategoryPhase.streaming);

    await _session.sendFrame(PhotoHashesEnvelope(
      entries: [
        for (final sha in hashed.keys)
          PhotoHashEntry(sha256: sha, pHash: pHashBySha[sha]),
      ],
    ).toBytes());

    final skipSet = <String>{};
    final waitForSkip = Completer<void>();
    final sub = _session.incomingFrames().listen((frame) {
      try {
        final env = TransferEnvelope.fromBytes(frame);
        if (env is PhotoSkipListEnvelope) {
          skipSet.addAll(env.skip);
          if (!waitForSkip.isCompleted) waitForSkip.complete();
        }
      } catch (_) {}
    });
    try {
      await waitForSkip.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      // proceed anyway
    }
    await sub.cancel();

    _update((s) => s.copyWith(photosSkippedPreflight: skipSet.length));

    for (final entry in hashed.entries) {
      final sha = entry.key;
      final f = entry.value;
      if (skipSet.contains(sha)) {
        onFileDone();
        continue;
      }
      await _session.sendFrame(MediaStartEnvelope(MediaHeader(
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
        final chunkSize =
            remaining < MediaReader.chunkBytes ? remaining : MediaReader.chunkBytes;
        final bytes = await reader.readChunk(f.uri, offset, chunkSize);
        if (bytes.isEmpty) break;
        await _session.sendFrame(MediaChunkEnvelope(
          sha256: sha,
          offset: offset,
          base64Bytes: base64.encode(bytes),
        ).toBytes());
        offset += bytes.length;
      }
      await _session.sendFrame(MediaEndEnvelope(sha256: sha).toBytes());
      onFileDone();
    }
  }

  // ──────────────────────────────────────────────────────────────── Receiver

  Future<void> _runAsReceiver() async {
    debugPrint('[RX] Starting receiver');
    _setFlow('perms');

    final neededPermissions = <Permission>{
      for (final c in _manifest.categories) ...permissionsFor(c),
    };
    for (final p in neededPermissions) {
      try {
        await p.request();
      } catch (_) {}
    }
    debugPrint('[RX] Permissions done');
    _setFlow('perms done');

    final cacheDir = (await getTemporaryDirectory()).path;
    final smsBufferPath = '$cacheDir/transfer_sms_buffer.jsonl';
    final callLogBufferPath = '$cacheDir/transfer_calllog_buffer.jsonl';

    final smsFile = File(smsBufferPath);
    final callLogFile = File(callLogBufferPath);
    if (await smsFile.exists()) await smsFile.delete();
    if (await callLogFile.exists()) await callLogFile.delete();

    IOSink? smsSink;
    IOSink? callLogSink;
    if (_manifest.categories.contains(DataCategory.sms)) {
      smsSink = smsFile.openWrite(mode: FileMode.append);
    }
    if (_manifest.categories.contains(DataCategory.callLog)) {
      callLogSink = callLogFile.openWrite(mode: FileMode.append);
    }

    final incomingContacts = <Contact>[];
    final incomingCalendar = <CalendarEvent>[];

    final mediaReader = MediaReader();
    final localMediaShas = <String>{};
    String? activeMediaSha;
    bool skippingActiveMedia = false;

    _onDone = Completer<void>();
    final readyCompleter = Completer<void>();
    debugPrint('[RX] Attaching listener');
    _setFlow('attaching listener');

    _incomingSub = _session.incomingFrames().listen(
      (frame) async {
        final frameNum = state.framesSeen + 1;
        // Yield every 20 frames to prevent ANR
        if (frameNum % 20 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        debugPrint('[RX] Frame $frameNum received (${frame.length} bytes)');
        _update((s) => s.copyWith(framesSeen: s.framesSeen + 1));
        try {
          final env = TransferEnvelope.fromBytes(frame);
          debugPrint('[RX] Frame $frameNum: ${env.runtimeType}');
          _update((s) => s.copyWith(lastFrameKind: env.runtimeType.toString()));

          switch (env) {
            case ManifestEnvelope():
              break;

            case CategoryAnnounceEnvelope(:final category, :final itemCount):
              debugPrint('[RX] CategoryAnnounce: $category ($itemCount items)');
              _setPhase(category, CategoryPhase.streaming);
              _setFlow('receiving $category ($itemCount items)');
              debugPrint('[RX] Sending CategoryAck for $category');
              Timer.run(() {
                _session
                    .sendFrame(CategoryAckEnvelope(category: category).toBytes())
                    .then((_) => debugPrint('[RX] CategoryAck sent for $category'))
                    .catchError((Object e) => debugPrint('[RX] CategoryAck error: $e'));
              });
              break;

            case SmsRecordEnvelope(:final record):
              debugPrint('[RX] SMS record, writing to disk...');
              smsSink?.writeln(jsonEncode(SmsRecordCodec.toJson(record)));
              debugPrint('[RX] SMS written');
              _incrementProcessed(DataCategory.sms);
              break;

            case CallLogRecordEnvelope(:final record):
              callLogSink?.writeln(jsonEncode(CallLogRecordCodec.toJson(record)));
              _incrementProcessed(DataCategory.callLog);
              break;

            case ContactRecordEnvelope(:final record):
              incomingContacts.add(record);
              _incrementProcessed(DataCategory.contacts);
              break;

            case CalendarEventEnvelope(:final record):
              incomingCalendar.add(record);
              _incrementProcessed(DataCategory.calendar);
              break;

            case CategorySentEnvelope(:final category):
              final count = state.processed[category] ?? 0;
              debugPrint('[RX] CategorySent: $category, processed $count');
              debugPrint('[RX] Sending CategoryReceived for $category');
              Timer.run(() {
                _session
                    .sendFrame(CategoryReceivedEnvelope(
                      category: category,
                      receivedCount: count,
                      missingIds: const [],
                    ).toBytes())
                    .then((_) => debugPrint('[RX] CategoryReceived sent for $category'))
                    .catchError((Object e) => debugPrint('[RX] CategoryReceived error: $e'));
              });
              _setFlow('$category received');
              break;

            case PhotoHashesEnvelope(:final entries):
              final skip = <String>[];
              for (final e in entries) {
                if (localMediaShas.contains(e.sha256)) {
                  skip.add(e.sha256);
                }
              }
              Timer.run(() {
                _session
                    .sendFrame(PhotoSkipListEnvelope(skip: skip).toBytes())
                    .catchError((Object _) {});
              });
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
                  _incrementSkipped(DataCategory.photos);
                } else {
                  mediaReader.writeEnd(sha256).then((ok) {
                    if (ok) {
                      _incrementWritten(DataCategory.photos);
                      localMediaShas.add(sha256);
                    } else {
                      _incrementSkipped(DataCategory.photos);
                    }
                  });
                }
                _incrementProcessed(DataCategory.photos);
                activeMediaSha = null;
              }
              break;

            case CategoryDoneEnvelope(:final category):
              _setPhase(category, CategoryPhase.done);
              break;

            case TransferDoneEnvelope():
              debugPrint('[RX] TransferDone received!');
              if (!_onDone!.isCompleted) _onDone!.complete();
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
          _update((s) => s.copyWith(frameError: e.toString()));
          if (!_onDone!.isCompleted) _onDone!.completeError(e);
        }
      },
      onError: (Object e) {
        _update((s) => s.copyWith(frameError: e.toString()));
        if (!_onDone!.isCompleted) _onDone!.completeError(e);
      },
      onDone: () {
        if (!_onDone!.isCompleted) {
          _onDone!.completeError(StateError('Peer disconnected'));
        }
      },
    );

    debugPrint('[RX] Sending Resume');
    _setFlow('sending Resume');
    try {
      await _session.sendFrame(ResumeEnvelope(watermarks: const {}).toBytes());
      debugPrint('[RX] Resume sent');
    } catch (e) {
      debugPrint('[RX] Resume send error: $e');
    }

    debugPrint('[RX] Waiting for Ready');
    _setFlow('waiting for Ready');
    await readyCompleter.future
        .timeout(const Duration(seconds: 30))
        .catchError((e) => debugPrint('[RX] Ready timeout: $e'));
    debugPrint('[RX] Ready received (or timeout)');

    debugPrint('[RX] Waiting for data...');
    _setFlow('waiting for data');
    await _onDone!.future;

    debugPrint('[RX] Data received, closing sinks');
    _setFlow('data received');

    await smsSink?.close();
    await callLogSink?.close();
    debugPrint('[RX] Sinks closed');

    debugPrint('[RX] Processing SMS from disk');
    _setFlow('processing SMS');
    if (_manifest.categories.contains(DataCategory.sms) &&
        await smsFile.exists()) {
      await _dedupAndWriteSmsFromDisk(smsBufferPath);
      await smsFile.delete();
      debugPrint('[RX] SMS processing complete');
    }

    _setFlow('processing Call Log');
    if (_manifest.categories.contains(DataCategory.callLog) &&
        await callLogFile.exists()) {
      await _dedupAndWriteCallLogFromDisk(callLogBufferPath);
      await callLogFile.delete();
    }

    _setFlow('processing Contacts');
    if (incomingContacts.isNotEmpty) {
      await _dedupAndWriteContacts(incomingContacts);
    }

    _setFlow('processing Calendar');
    if (incomingCalendar.isNotEmpty) {
      await _dedupAndWriteCalendar(incomingCalendar);
    }

    _setFlow('all done');
  }

  Future<void> _dedupAndWriteSmsFromDisk(String path) async {
    final file = File(path);
    if (!await file.exists()) return;

    final smsIndex = SmsDedup.indexOf(await SmsReader().readAll());
    final toWrite = <SmsRecord>[];

    final lines = await file.readAsLines();
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        final record = SmsRecordCodec.fromJson(json);
        if (SmsDedup.isDuplicate(smsIndex, record)) {
          _incrementSkipped(DataCategory.sms);
        } else {
          toWrite.add(record);
        }
      } catch (_) {}
    }

    if (toWrite.isNotEmpty) {
      final reader = SmsReader();
      final granted =
          await reader.isDefaultSmsApp() || await reader.requestSmsRole();
      if (granted) {
        final written = await reader.writeAll(toWrite);
        final w = Map<DataCategory, int>.from(state.written);
        w[DataCategory.sms] = (w[DataCategory.sms] ?? 0) + written;
        _update((s) => s.copyWith(written: w));
      } else {
        final sk = Map<DataCategory, int>.from(state.skipped);
        sk[DataCategory.sms] = (sk[DataCategory.sms] ?? 0) + toWrite.length;
        _update((s) => s.copyWith(skipped: sk));
      }
    }
    _setPhase(DataCategory.sms, CategoryPhase.done);
  }

  Future<void> _dedupAndWriteCallLogFromDisk(String path) async {
    final file = File(path);
    if (!await file.exists()) return;

    final callLogIndex = CallLogDedup.indexOf(await CallLogReader().readAll());
    final toWrite = <CallLogRecord>[];

    final lines = await file.readAsLines();
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        final record = CallLogRecordCodec.fromJson(json);
        if (CallLogDedup.isDuplicate(callLogIndex, record)) {
          _incrementSkipped(DataCategory.callLog);
        } else {
          toWrite.add(record);
        }
      } catch (_) {}
    }

    if (toWrite.isNotEmpty) {
      final written = await CallLogReader().writeAll(toWrite);
      final w = Map<DataCategory, int>.from(state.written);
      w[DataCategory.callLog] = (w[DataCategory.callLog] ?? 0) + written;
      _update((s) => s.copyWith(written: w));
    }
    _setPhase(DataCategory.callLog, CategoryPhase.done);
  }

  Future<void> _dedupAndWriteContacts(List<Contact> incoming) async {
    final contactsKeys = <Set<String>>[
      for (final c in await ContactsReader().readAll())
        ContactsDedup.matchKeysFor(c),
    ];
    final toWrite = <Contact>[];
    for (final r in incoming) {
      final keys = ContactsDedup.matchKeysFor(r);
      final isDup = keys.isNotEmpty &&
          contactsKeys.any(
              (existing) => existing.intersection(keys).length == keys.length);
      if (isDup) {
        _incrementSkipped(DataCategory.contacts);
      } else {
        toWrite.add(r);
      }
    }
    if (toWrite.isNotEmpty) {
      final written = await ContactsReader().writeAll(toWrite);
      final w = Map<DataCategory, int>.from(state.written);
      w[DataCategory.contacts] = (w[DataCategory.contacts] ?? 0) + written;
      _update((s) => s.copyWith(written: w));
    }
    _setPhase(DataCategory.contacts, CategoryPhase.done);
  }

  Future<void> _dedupAndWriteCalendar(List<CalendarEvent> incoming) async {
    final calendarIndex =
        CalendarDedup.indexOf(await CalendarReader().readAll());
    final toWrite = <CalendarEvent>[];
    for (final r in incoming) {
      if (CalendarDedup.isDuplicate(calendarIndex, r)) {
        _incrementSkipped(DataCategory.calendar);
      } else {
        toWrite.add(r);
      }
    }
    if (toWrite.isNotEmpty) {
      final written = await CalendarReader().writeAll(toWrite);
      final w = Map<DataCategory, int>.from(state.written);
      w[DataCategory.calendar] = (w[DataCategory.calendar] ?? 0) + written;
      _update((s) => s.copyWith(written: w));
    }
    _setPhase(DataCategory.calendar, CategoryPhase.done);
  }
}

final transferControllerProvider =
    StateNotifierProvider.family<TransferController, TransferProgress, TransferParams>(
  (ref, params) => TransferController(
    params.session,
    params.manifest,
    params.role,
  ),
);
