import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/dedup/calendar_dedup.dart';
import '../core/dedup/call_log_dedup.dart';
import '../core/dedup/contacts_dedup.dart';
import '../core/model/calendar_event.dart';
import '../core/model/call_log_record.dart';
import '../core/model/contact.dart';
import '../core/transfer/manifest.dart';
import '../core/transfer/transport.dart';
import '../platform/calendar_reader.dart';
import '../platform/call_log_reader.dart';
import '../platform/contacts_reader.dart';
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
        case DataCategory.sms:
        case DataCategory.photos:
          // v0.5: SMS needs the default-SMS-app role grab; photos need
          // chunked file-byte streaming. Wired in later releases.
          break;
      }
      await session.sendFrame(CategoryDoneEnvelope(category).toBytes());
    }
    await session.sendFrame(const TransferDoneEnvelope().toBytes());
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

    final pendingCallLogWrites = <CallLogRecord>[];
    final pendingContactWrites = <Contact>[];
    final pendingCalendarWrites = <CalendarEvent>[];
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
            case CategoryDoneEnvelope(:final category):
              switch (category) {
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
                case DataCategory.sms:
                case DataCategory.photos:
                  // No writer wired yet for these; nothing to flush.
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
    final hasWriter = c == DataCategory.callLog ||
        c == DataCategory.contacts ||
        c == DataCategory.calendar;
    final detail = isReceiver && hasWriter
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

