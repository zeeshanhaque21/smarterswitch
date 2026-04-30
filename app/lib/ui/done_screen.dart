import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/transfer/manifest.dart';
import '../state/transfer_state.dart';

class DoneScreen extends ConsumerWidget {
  const DoneScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(transferStateProvider);
    final manifest = state.senderManifest;
    final isReceiver = state.role == DeviceRole.receiver;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Done'),
        automaticallyImplyLeading: false,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 24),
            const Icon(Icons.check_circle, size: 96, color: Colors.green),
            const SizedBox(height: 16),
            Text(
              isReceiver ? 'Transfer received' : 'Transfer sent',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 24),
            if (manifest != null) ..._categoryRows(state, manifest),
            const Spacer(),
            FilledButton(
              onPressed: () {
                ref.read(transferStateProvider.notifier).clearPairedSession();
                context.go('/');
              },
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _categoryRows(TransferState state, TransferManifest manifest) {
    final isReceiver = state.role == DeviceRole.receiver;
    return [
      for (final c in manifest.categories)
        _Row(
          _labelFor(c),
          isReceiver
              ? _receiverDetail(c, state, manifest)
              : '${manifest.counts[c] ?? 0} sent',
        ),
    ];
  }

  String _receiverDetail(
    DataCategory c,
    TransferState state,
    TransferManifest manifest,
  ) {
    final written = state.writtenByCategory[c] ?? 0;
    final skipped = state.skippedByCategory[c] ?? 0;
    final total = manifest.counts[c] ?? 0;
    final hasWriter = c == DataCategory.callLog ||
        c == DataCategory.contacts ||
        c == DataCategory.calendar;
    if (hasWriter) {
      return '$written new, $skipped duplicates skipped (of $total)';
    }
    // Other categories: writers not yet implemented.
    return '$total received (writer arrives in a later release)';
  }

  static String _labelFor(DataCategory c) {
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

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
