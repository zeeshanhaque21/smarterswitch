import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/transfer_state.dart';

/// Per-category preview of what's about to transfer, taken from the
/// manifest the OLD phone sent to the NEW phone. Same numbers render on
/// both sides because both are reading the same manifest.
///
/// In v1 the receiver's dedup index will run here too and produce the
/// duplicates/new split per category. v0.2 just shows the source counts —
/// no dedup yet — so users see exactly what they picked.
class ScanScreen extends ConsumerWidget {
  const ScanScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(transferStateProvider);
    final manifest = state.senderManifest;

    if (manifest == null) {
      // The receiver shouldn't ever reach this screen without a manifest
      // (the Waiting screen blocks until one arrives), but be defensive.
      return Scaffold(
        appBar: AppBar(title: const Text('Scanning')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No transfer plan yet. Go back and re-pair.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final isReceiver = state.role == DeviceRole.receiver;
    final headlineLabel = isReceiver
        ? 'Incoming from ${manifest.senderDisplayName}'
        : 'About to transfer';
    final totalItems =
        manifest.counts.values.fold<int>(0, (a, b) => a + b);

    return Scaffold(
      appBar: AppBar(title: const Text('Review')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              headlineLabel,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Text(
              '$totalItems items across ${manifest.categories.length} categor'
              '${manifest.categories.length == 1 ? "y" : "ies"}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView.separated(
                itemCount: manifest.categories.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final c = manifest.categories[i];
                  return ListTile(
                    leading: Icon(_iconFor(c)),
                    title: Text(_labelFor(c)),
                    trailing: Text(
                      '${manifest.counts[c] ?? 0}',
                      style: const TextStyle(
                        fontFeatures: [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: () => context.go('/transfer'),
            child: Text(isReceiver
                ? 'Accept and start transfer'
                : 'Start transfer'),
          ),
        ),
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
