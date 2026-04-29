import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/transfer_state.dart';

class TransferScreen extends ConsumerStatefulWidget {
  const TransferScreen({super.key});

  @override
  ConsumerState<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends ConsumerState<TransferScreen> {
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _animate();
  }

  Future<void> _animate() async {
    for (var i = 1; i <= 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted) return;
      setState(() => _progress = i / 10);
    }
    if (!mounted) return;
    context.go('/done');
  }

  @override
  Widget build(BuildContext context) {
    final scan = ref.watch(transferStateProvider).scanResult;
    return Scaffold(
      appBar: AppBar(title: const Text('Transferring')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 16),
            Text(
                '${(_progress * (scan?.newRecords ?? 0)).toInt()} / ${scan?.newRecords ?? 0} new SMS'),
            const SizedBox(height: 8),
            const Text('Resumable if Wi-Fi drops.'),
          ],
        ),
      ),
    );
  }
}
