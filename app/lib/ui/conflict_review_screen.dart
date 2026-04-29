import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/dedup/contacts_dedup.dart';
import '../core/dedup/photos_dedup.dart';
import '../core/model/contact.dart';
import '../core/model/media_record.dart';
import '../state/conflicts.dart';
import '../state/transfer_state.dart';

/// Screen that walks the user through fuzzy-match conflicts before transfer.
/// Each row offers three decisions: Keep both (default), Keep this device's
/// version, Replace with the source. Default-keep-both means hesitating
/// users never lose data.
class ConflictReviewScreen extends ConsumerWidget {
  const ConflictReviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(transferStateProvider);
    final notifier = ref.read(transferStateProvider.notifier);
    final conflicts = state.conflicts;

    if (conflicts.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Review conflicts')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Nothing to review — no fuzzy matches were found.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              onPressed: () => context.go('/transfer'),
              child: const Text('Continue to transfer'),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Review ${conflicts.length} conflict${conflicts.length == 1 ? "" : "s"}'),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: conflicts.length,
        itemBuilder: (context, i) {
          final conflict = conflicts[i];
          final decision =
              state.conflictDecisions[i] ?? ConflictDecision.keepBoth;
          return _ConflictCard(
            conflict: conflict,
            decision: decision,
            onDecide: (d) => notifier.resolveConflict(i, d),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: () => context.go('/transfer'),
            child: const Text('Continue to transfer'),
          ),
        ),
      ),
    );
  }
}

class _ConflictCard extends StatelessWidget {
  const _ConflictCard({
    required this.conflict,
    required this.decision,
    required this.onDecide,
  });

  final Conflict conflict;
  final ConflictDecision decision;
  final ValueChanged<ConflictDecision> onDecide;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Chip(
                  label: Text(conflict.kindLabel),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 8),
                Text(_confidenceLabel(conflict)),
              ],
            ),
            const SizedBox(height: 12),
            _ConflictBody(conflict: conflict),
            const SizedBox(height: 12),
            SegmentedButton<ConflictDecision>(
              segments: const [
                ButtonSegment(
                  value: ConflictDecision.keepBoth,
                  label: Text('Keep both'),
                ),
                ButtonSegment(
                  value: ConflictDecision.keepTarget,
                  label: Text('Keep this'),
                ),
                ButtonSegment(
                  value: ConflictDecision.keepSource,
                  label: Text('Use source'),
                ),
              ],
              selected: {decision},
              onSelectionChanged: (s) => onDecide(s.first),
            ),
          ],
        ),
      ),
    );
  }

  String _confidenceLabel(Conflict c) {
    switch (c) {
      case ContactConflictItem(:final inner):
        final pct = (inner.confidence * 100).round();
        return '$pct% match — ${inner.sharedKeys.length} shared field${inner.sharedKeys.length == 1 ? "" : "s"}';
      case PhotoConflictItem(:final inner):
        return '${inner.hammingDistance} of 64 bits differ';
    }
  }
}

class _ConflictBody extends StatelessWidget {
  const _ConflictBody({required this.conflict});
  final Conflict conflict;

  @override
  Widget build(BuildContext context) {
    switch (conflict) {
      case ContactConflictItem(:final inner):
        return _ContactBody(inner: inner);
      case PhotoConflictItem(:final inner):
        return _PhotoBody(inner: inner);
    }
  }
}

class _ContactBody extends StatelessWidget {
  const _ContactBody({required this.inner});
  final ContactConflict inner;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ContactRow(label: 'On source', contact: inner.source),
        const Divider(height: 24),
        _ContactRow(label: 'On this device', contact: inner.candidate),
        if (inner.sharedKeys.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Shared: ${inner.sharedKeys.join(", ")}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

class _ContactRow extends StatelessWidget {
  const _ContactRow({required this.label, required this.contact});
  final String label;
  final Contact contact;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        Text(contact.displayName,
            style: Theme.of(context).textTheme.titleMedium),
        if (contact.phones.isNotEmpty) Text(contact.phones.join(', ')),
        if (contact.emails.isNotEmpty) Text(contact.emails.join(', ')),
      ],
    );
  }
}

class _PhotoBody extends StatelessWidget {
  const _PhotoBody({required this.inner});
  final PhotoConflict inner;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PhotoRow(label: 'On source', record: inner.source),
        const Divider(height: 24),
        _PhotoRow(label: 'On this device', record: inner.candidate),
      ],
    );
  }
}

class _PhotoRow extends StatelessWidget {
  const _PhotoRow({required this.label, required this.record});
  final String label;
  final MediaRecord record;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        Text(record.fileName,
            style: Theme.of(context).textTheme.titleMedium),
        Text(_formatBytes(record.byteSize)),
      ],
    );
  }

  static String _formatBytes(int b) {
    const kib = 1024;
    const mib = kib * 1024;
    if (b < kib) return '$b B';
    if (b < mib) return '${(b / kib).toStringAsFixed(1)} KB';
    return '${(b / mib).toStringAsFixed(1)} MB';
  }
}
