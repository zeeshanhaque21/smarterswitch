import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/transfer/manifest.dart';
import '../state/transfer_controller.dart';
import '../state/transfer_progress.dart';
import '../state/transfer_state.dart';

class TransferScreen extends ConsumerStatefulWidget {
  const TransferScreen({super.key});

  @override
  ConsumerState<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends ConsumerState<TransferScreen> {
  TransferParams? _params;
  bool _startCalled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initAndStart());
  }

  void _initAndStart() {
    final state = ref.read(transferStateProvider);
    final session = state.pairedSession;
    final manifest = state.senderManifest;
    if (session == null || manifest == null) {
      return;
    }
    _params = TransferParams(
      session: session,
      manifest: manifest,
      role: state.role,
    );
    setState(() {});
    if (!_startCalled) {
      _startCalled = true;
      ref.read(transferControllerProvider(_params!).notifier).start().then((_) {
        final p = ref.read(transferControllerProvider(_params!));
        if (p.done && p.error == null && mounted) {
          ref
              .read(transferStateProvider.notifier)
              .setTransferTallies(p.written, p.skipped);
          Future.delayed(const Duration(milliseconds: 600), () {
            if (mounted) context.go('/done');
          });
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tState = ref.watch(transferStateProvider);
    final manifest = tState.senderManifest;
    if (manifest == null || _params == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Transferring')),
        body: const Center(child: Text('Nothing to transfer.')),
      );
    }

    final progress = ref.watch(transferControllerProvider(_params!));

    if (progress.error != null) {
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
              Text(progress.error!, textAlign: TextAlign.center),
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

    final isReceiver = tState.role == DeviceRole.receiver;

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
            _DiagnosticStrip(progress: progress),
            const SizedBox(height: 8),
            if (_isHashingPhase(tState.role, progress))
              _HashingBanner(progress: progress),
            const SizedBox(height: 8),
            for (final c in manifest.categories)
              _CategoryRow(
                category: c,
                manifest: manifest,
                progress: progress,
                isReceiver: isReceiver,
              ),
            const Spacer(),
            Center(
              child: Text(
                progress.done ? 'Done — finalizing…' : 'Working…',
                style: progress.done
                    ? null
                    : const TextStyle(fontStyle: FontStyle.italic),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _isHashingPhase(DeviceRole role, TransferProgress p) {
    if (role != DeviceRole.sender) return false;
    if (p.hashTotal == 0) return false;
    return p.hashed < p.hashTotal;
  }
}

class _DiagnosticStrip extends StatelessWidget {
  const _DiagnosticStrip({required this.progress});
  final TransferProgress progress;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      color: Colors.grey.shade200,
      child: DefaultTextStyle.merge(
        style: const TextStyle(fontSize: 11, color: Colors.black87),
        child: Column(
          children: [
            Text('state: ${progress.flowState} | frames: ${progress.framesSeen}'),
            Text(
                'last: ${progress.lastFrameKind}${progress.frameError != null ? " | err: ${progress.frameError}" : ""}'),
          ],
        ),
      ),
    );
  }
}

class _HashingBanner extends StatelessWidget {
  const _HashingBanner({required this.progress});
  final TransferProgress progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pct =
        progress.hashTotal == 0 ? 0.0 : progress.hashed / progress.hashTotal;
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
              'Hashing ${progress.hashed} / ${progress.hashTotal} — first run only; future '
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
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.category,
    required this.manifest,
    required this.progress,
    required this.isReceiver,
  });

  final DataCategory category;
  final TransferManifest manifest;
  final TransferProgress progress;
  final bool isReceiver;

  @override
  Widget build(BuildContext context) {
    final total = manifest.counts[category] ?? 0;
    final done =
        isReceiver ? (progress.processed[category] ?? 0) : (progress.sent[category] ?? 0);

    final phase = progress.phases[category] ??
        (isReceiver
            ? (done == 0 && total > 0
                ? CategoryPhase.queued
                : (done < total ? CategoryPhase.streaming : CategoryPhase.done))
            : CategoryPhase.queued);

    final progressVal = category == DataCategory.photos &&
            !isReceiver &&
            phase == CategoryPhase.preparing &&
            progress.hashTotal > 0
        ? (progress.hashed / progress.hashTotal).clamp(0.0, 1.0)
        : (total == 0 ? 1.0 : (done / total).clamp(0.0, 1.0));

    final phaseLabel = _phaseLabel(category, phase, isReceiver);
    final phaseColor = _phaseColor(context, phase);
    final detail = _detailLine(category, phase, total, done, progress, isReceiver);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(_iconFor(category), size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(_labelFor(category))),
              if (phaseLabel != null) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
              Text(
                detail,
                style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: progressVal),
        ],
      ),
    );
  }

  String? _phaseLabel(DataCategory c, CategoryPhase phase, bool isReceiver) {
    switch (phase) {
      case CategoryPhase.queued:
        return 'Queued';
      case CategoryPhase.preparing:
        if (c == DataCategory.photos && !isReceiver) return 'Hashing';
        return 'Reading';
      case CategoryPhase.streaming:
        return null;
      case CategoryPhase.done:
        return 'Done';
    }
  }

  Color _phaseColor(BuildContext context, CategoryPhase phase) {
    switch (phase) {
      case CategoryPhase.queued:
        return Colors.grey;
      case CategoryPhase.preparing:
      case CategoryPhase.streaming:
        return Theme.of(context).colorScheme.primary;
      case CategoryPhase.done:
        return Colors.green;
    }
  }

  String _detailLine(
    DataCategory c,
    CategoryPhase phase,
    int total,
    int done,
    TransferProgress p,
    bool isReceiver,
  ) {
    if (c == DataCategory.photos && !isReceiver && phase == CategoryPhase.preparing) {
      return 'Hashing ${p.hashed} / ${p.hashTotal}';
    }
    if (isReceiver) {
      return '$done / $total received '
          '(${p.written[c] ?? 0} new, '
          '${p.skipped[c] ?? 0} duplicates)';
    }
    if (c == DataCategory.photos && p.photosSkippedPreflight > 0) {
      return '$done / $total sent '
          '(${p.photosSkippedPreflight} skipped — already on the other phone)';
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
