import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/transfer_state.dart';

class PairScreen extends ConsumerWidget {
  const PairScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(transferStateProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: const Text('SmarterSwitch')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 24),
            Text(
              'Move data between two phones — without duplicates.',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Both phones run this app on the same Wi-Fi. No cloud, no account.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const Spacer(),
            FilledButton.icon(
              icon: const Icon(Icons.upload),
              label: const Text('This phone is the SOURCE'),
              onPressed: () {
                notifier.setRole(DeviceRole.sender);
                context.go('/select');
              },
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.download),
              label: const Text('This phone is the TARGET'),
              onPressed: () {
                notifier.setRole(DeviceRole.receiver);
                context.go('/select');
              },
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}
