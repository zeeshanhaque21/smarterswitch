import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../platform/category_counts.dart';
import '../state/transfer_state.dart';

class SelectScreen extends ConsumerStatefulWidget {
  const SelectScreen({super.key});

  @override
  ConsumerState<SelectScreen> createState() => _SelectScreenState();
}

class _SelectScreenState extends ConsumerState<SelectScreen> {
  bool _probing = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runProbe());
  }

  Future<void> _runProbe() async {
    setState(() => _probing = true);
    await ref.read(transferStateProvider.notifier).probeAllCategoryCounts();
    if (mounted) setState(() => _probing = false);
  }

  Future<void> _requestPermissionFor(DataCategory category) async {
    final results = await Future.wait(
      permissionsFor(category).map((p) => p.request()),
    );
    final anyGranted = results.any((s) => s.isGranted || s.isLimited);
    if (anyGranted) {
      await ref.read(transferStateProvider.notifier).probeAllCategoryCounts();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(transferStateProvider);
    final notifier = ref.read(transferStateProvider.notifier);

    final allOn = state.selectedCategories.length == kCategoryDisplayOrder.length;
    final selectedCount = _selectedItemTotal(state);
    final canContinue = state.selectedCategories.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Choose data to transfer')),
      body: ListView(
        children: [
          SwitchListTile(
            title: Text(allOn ? 'Deselect all' : 'Select all'),
            subtitle: const Text('Toggle every category at once'),
            value: allOn,
            onChanged: (v) => notifier.setAllCategories(v),
          ),
          const Divider(height: 1),
          for (final category in kCategoryDisplayOrder)
            _CategoryRow(
              category: category,
              status: state.categoryStatuses[category],
              selected: state.selectedCategories.contains(category),
              probing: _probing,
              onToggle: () => notifier.toggleCategory(category),
              onRequestPermission: () => _requestPermissionFor(category),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: canContinue ? () => context.go('/scan') : null,
            child: Text(
              canContinue
                  ? 'Continue with ${state.selectedCategories.length} categor${state.selectedCategories.length == 1 ? "y" : "ies"}'
                      ' ($selectedCount item${selectedCount == 1 ? "" : "s"})'
                  : 'Pick at least one category',
            ),
          ),
        ),
      ),
    );
  }

  int _selectedItemTotal(TransferState state) {
    var total = 0;
    for (final c in state.selectedCategories) {
      total += state.categoryStatuses[c]?.count ?? 0;
    }
    return total;
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.category,
    required this.status,
    required this.selected,
    required this.probing,
    required this.onToggle,
    required this.onRequestPermission,
  });

  final DataCategory category;
  final CategoryStatus? status;
  final bool selected;
  final bool probing;
  final VoidCallback onToggle;
  final VoidCallback onRequestPermission;

  @override
  Widget build(BuildContext context) {
    final meta = _metaFor(category);
    final permissionDenied =
        status?.permissionState == PermissionState.denied;

    return CheckboxListTile(
      value: selected,
      onChanged: (_) => onToggle(),
      title: Row(
        children: [
          Icon(meta.icon),
          const SizedBox(width: 12),
          Expanded(child: Text(meta.label)),
          _trailing(context),
        ],
      ),
      subtitle: _subtitle(context, permissionDenied),
    );
  }

  Widget _trailing(BuildContext context) {
    if (probing && status == null) {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    final s = status;
    if (s == null) return const SizedBox.shrink();
    if (s.permissionState == PermissionState.denied) {
      return TextButton(
        onPressed: onRequestPermission,
        child: const Text('Tap to allow'),
      );
    }
    if (s.count == null) {
      return const Text('—');
    }
    return Text(
      _formatCount(s.count!),
      style: const TextStyle(
        fontFeatures: [FontFeature.tabularFigures()],
        fontWeight: FontWeight.w500,
      ),
    );
  }

  Widget? _subtitle(BuildContext context, bool permissionDenied) {
    final s = status;
    if (permissionDenied) {
      return const Text('Permission needed for this device');
    }
    if (s?.estimatedBytes != null && s!.estimatedBytes! > 0) {
      return Text('${_formatBytes(s.estimatedBytes!)} on this device');
    }
    return null;
  }

  static String _formatCount(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}K';
    return '${(n / 1000000).toStringAsFixed(1)}M';
  }

  static String _formatBytes(int b) {
    const kib = 1024;
    const mib = kib * 1024;
    const gib = mib * 1024;
    if (b < kib) return '$b B';
    if (b < mib) return '${(b / kib).toStringAsFixed(1)} KB';
    if (b < gib) return '${(b / mib).toStringAsFixed(1)} MB';
    return '${(b / gib).toStringAsFixed(2)} GB';
  }

  _CategoryMeta _metaFor(DataCategory c) {
    switch (c) {
      case DataCategory.sms:
        return const _CategoryMeta('SMS / MMS', Icons.sms_outlined);
      case DataCategory.callLog:
        return const _CategoryMeta('Call log', Icons.call_outlined);
      case DataCategory.contacts:
        return const _CategoryMeta('Contacts', Icons.person_outline);
      case DataCategory.photos:
        return const _CategoryMeta(
          'Photos & videos',
          Icons.photo_library_outlined,
        );
      case DataCategory.calendar:
        return const _CategoryMeta(
          'Calendar',
          Icons.calendar_today_outlined,
        );
    }
  }
}

class _CategoryMeta {
  const _CategoryMeta(this.label, this.icon);
  final String label;
  final IconData icon;
}
