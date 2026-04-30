import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/transfer/manifest.dart';
import '../state/transfer_state.dart';

/// Receiver-side post-pair holding screen.
///
/// After the NEW phone completes the pair handshake, the OLD phone is the
/// one picking what to send. We sit on this screen until the OLD phone's
/// manifest arrives over the live session, then advance to /scan.
class WaitingForSourceScreen extends ConsumerStatefulWidget {
  const WaitingForSourceScreen({super.key});

  @override
  ConsumerState<WaitingForSourceScreen> createState() =>
      _WaitingForSourceScreenState();
}

class _WaitingForSourceScreenState
    extends ConsumerState<WaitingForSourceScreen> {
  StreamSubscription? _sub;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _listenForManifest());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _listenForManifest() {
    final session = ref.read(transferStateProvider).pairedSession;
    if (session == null) {
      setState(() => _error = 'No active session — please re-pair.');
      return;
    }
    _sub = session.incomingFrames().listen(
      (frame) {
        try {
          final manifest = TransferManifest.fromBytes(frame);
          ref
              .read(transferStateProvider.notifier)
              .setSenderManifest(manifest);
          if (mounted) context.go('/scan');
        } catch (e) {
          if (mounted) setState(() => _error = 'Bad manifest: $e');
        }
      },
      onError: (Object e) {
        if (mounted) setState(() => _error = 'Connection error: $e');
      },
      onDone: () {
        if (mounted && ref.read(transferStateProvider).senderManifest == null) {
          setState(() => _error = 'The other phone disconnected.');
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(transferStateProvider);
    final peer = state.peerName ?? 'the other phone';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Waiting for the other phone'),
        automaticallyImplyLeading: false,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_error == null) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              Text(
                'Connected to $peer.',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Waiting for it to choose what to send…',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Text(
                'On the OLD phone, pick the categories you want to bring '
                'over and tap Continue.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ] else ...[
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
          ],
        ),
      ),
    );
  }
}
