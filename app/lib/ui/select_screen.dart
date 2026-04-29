import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/transfer_state.dart';

class SelectScreen extends ConsumerWidget {
  const SelectScreen({super.key});

  static const _categories = <_CategoryRow>[
    _CategoryRow(DataCategory.sms, 'SMS / MMS', Icons.sms_outlined,
        supportedNow: true),
    _CategoryRow(DataCategory.callLog, 'Call log', Icons.call_outlined,
        supportedNow: false),
    _CategoryRow(DataCategory.contacts, 'Contacts', Icons.person_outline,
        supportedNow: false),
    _CategoryRow(DataCategory.photos, 'Photos & videos',
        Icons.photo_library_outlined,
        supportedNow: false),
    _CategoryRow(DataCategory.calendar, 'Calendar', Icons.calendar_today_outlined,
        supportedNow: false),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(transferStateProvider);
    final notifier = ref.read(transferStateProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: const Text('Choose data to transfer')),
      body: ListView(
        children: [
          for (final c in _categories)
            CheckboxListTile(
              value: state.selectedCategories.contains(c.category),
              onChanged: c.supportedNow
                  ? (_) => notifier.toggleCategory(c.category)
                  : null,
              title: Row(
                children: [
                  Icon(c.icon),
                  const SizedBox(width: 12),
                  Expanded(child: Text(c.label)),
                  if (!c.supportedNow)
                    const Chip(
                      label: Text('Phase 2', style: TextStyle(fontSize: 11)),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
              subtitle: c.supportedNow ? null : const Text('Coming soon'),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: state.selectedCategories.isEmpty
                ? null
                : () => context.go('/scan'),
            child: const Text('Continue'),
          ),
        ),
      ),
    );
  }
}

class _CategoryRow {
  const _CategoryRow(this.category, this.label, this.icon,
      {required this.supportedNow});
  final DataCategory category;
  final String label;
  final IconData icon;
  final bool supportedNow;
}
