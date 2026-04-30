import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/transfer_state.dart';

/// Per-category progress UI driven from the manifest. The actual byte-level
/// transfer logic isn't wired yet (writers per category come in v0.3); for
/// now this is a fake animation that visibly progresses through the
/// categories the user actually picked, so the user sees their choice
/// reflected instead of a hardcoded "X new SMS".
class TransferScreen extends ConsumerStatefulWidget {
  const TransferScreen({super.key});

  @override
  ConsumerState<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends ConsumerState<TransferScreen> {
  int _categoryIdx = 0;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _animate());
  }

  Future<void> _animate() async {
    final manifest = ref.read(transferStateProvider).senderManifest;
    if (manifest == null) {
      if (mounted) context.go('/done');
      return;
    }
    for (var c = 0; c < manifest.categories.length; c++) {
      if (!mounted) return;
      setState(() {
        _categoryIdx = c;
        _progress = 0;
      });
      // Animate ten ticks per category.
      for (var i = 1; i <= 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        if (!mounted) return;
        setState(() => _progress = i / 10);
      }
    }
    if (mounted) context.go('/done');
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(transferStateProvider);
    final manifest = state.senderManifest;
    if (manifest == null || manifest.categories.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Transferring')),
        body: const Center(child: Text('Nothing to transfer.')),
      );
    }
    final current = manifest.categories[_categoryIdx];
    final currentCount = manifest.counts[current] ?? 0;
    final isReceiver = state.role == DeviceRole.receiver;

    return Scaffold(
      appBar: AppBar(
        title: Text(isReceiver ? 'Receiving' : 'Sending'),
        automaticallyImplyLeading: false,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 32),
            Text(
              '${_categoryIdx + 1} of ${manifest.categories.length}: ${_labelFor(current)}',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 12),
            Text(
              '${(_progress * currentCount).toInt()} / $currentCount items',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),
            Text(
              'Plan',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < manifest.categories.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      i < _categoryIdx
                          ? Icons.check_circle
                          : i == _categoryIdx
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                      size: 18,
                      color: i < _categoryIdx
                          ? Colors.green
                          : Theme.of(context).colorScheme.outline,
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(_labelFor(manifest.categories[i]))),
                    Text('${manifest.counts[manifest.categories[i]] ?? 0}'),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
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
