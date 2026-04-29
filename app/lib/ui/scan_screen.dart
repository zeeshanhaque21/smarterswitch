import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/transfer_state.dart';

/// Scan screen: in the real flow this is where the receiver indexes its local
/// data and the sender streams a hash manifest. Phase 1 simulates a result so
/// the rest of the flow is exercisable end-to-end without a peer.
class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  bool _scanning = true;

  @override
  void initState() {
    super.initState();
    _runFakeScan();
  }

  Future<void> _runFakeScan() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    ref.read(transferStateProvider.notifier).setScanResult(
          const ScanResult(
            sourceTotal: 5234,
            targetTotal: 4187,
            duplicates: 4012,
            newRecords: 1222,
          ),
        );
    setState(() => _scanning = false);
  }

  @override
  Widget build(BuildContext context) {
    final scan = ref.watch(transferStateProvider).scanResult;
    return Scaffold(
      appBar: AppBar(title: const Text('Scanning')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: _scanning || scan == null
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Hashing local SMS and matching against peer…'),
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Stat('Source phone', '${scan.sourceTotal} messages'),
                  _Stat('Target phone (this device)',
                      '${scan.targetTotal} messages'),
                  const Divider(),
                  _Stat('Duplicates (will skip)', '${scan.duplicates}',
                      emphasis: false),
                  _Stat('New (will transfer)', '${scan.newRecords}',
                      emphasis: true),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => context.go('/transfer'),
                    child: const Text('Start transfer'),
                  ),
                ],
              ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, {this.emphasis = false});
  final String label;
  final String value;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          Text(
            value,
            style: emphasis
                ? Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)
                : Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}
