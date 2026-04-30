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
            if (state.previousSmsAppPackage != null && isReceiver) ...[
              const SizedBox(height: 24),
              _SmsRestoreBanner(previousPackage: state.previousSmsAppPackage!),
            ],
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
    // All five categories have writers as of v0.7.
    return '$written new, $skipped duplicates skipped (of $total)';
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

/// Banner the receiver shows when SmarterSwitch grabbed the default-SMS-app
/// role to write incoming messages. Android doesn't let us programmatically
/// hand the role back, so we tell the user which app they were using before
/// — opening it is usually enough; most SMS apps prompt to be default again
/// on launch.
class _SmsRestoreBanner extends StatelessWidget {
  const _SmsRestoreBanner({required this.previousPackage});
  final String previousPackage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline,
                    color: theme.colorScheme.onTertiaryContainer),
                const SizedBox(width: 12),
                Text(
                  'SmarterSwitch is your default SMS app.',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Open $previousPackage (or go to Settings → Default apps → SMS app) '
              'to switch the role back.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
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
