import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/transfer/manifest.dart';
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _requestAllAndProbe());
  }

  /// Request every permission the five categories need in one batch, then
  /// probe counts. permission_handler short-circuits already-decided
  /// permissions (granted / permanently denied), so re-entering the screen
  /// after the user has answered doesn't re-prompt.
  ///
  /// Without this, a fresh install lands on the Select screen with all five
  /// rows showing "Tap to allow" and the bottom CTA reading "0 items"
  /// because counts can't be queried without permission.
  ///
  /// Skipped when state is already populated — that means either a
  /// re-navigation (we already have counts; just refresh) or a test with
  /// seeded state (where the platform channels would hang).
  Future<void> _requestAllAndProbe() async {
    setState(() => _probing = true);
    final alreadyHaveData =
        ref.read(transferStateProvider).categoryStatuses.isNotEmpty;
    if (!alreadyHaveData) {
      // Fire-and-forget the permission requests. Awaiting Future.wait
      // here used to block the whole flow if even one permission's
      // request() Future never resolved (permission_handler has had
      // edge cases on certain OEMs around permanentlyDenied returning
      // a never-completing Future). Probes run regardless: any
      // not-yet-granted category surfaces as "Tap to allow" via the
      // existing per-row inline CTA, and a single tap re-prompts that
      // one permission and re-probes.
      final allPermissions = <Permission>{
        for (final c in kCategoryDisplayOrder) ...permissionsFor(c),
      };
      for (final p in allPermissions) {
        // ignore: discarded_futures
        p.request().catchError((Object _) {
          // Best-effort; failures are reflected in the per-row state.
          return PermissionStatus.denied;
        });
      }
    }
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

    final allOn = state.selectedCategories.length == kEnabledCategories.length;
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
              enabled: kEnabledCategories.contains(category),
              onToggle: () => notifier.toggleCategory(category),
              onRequestPermission: () => _requestPermissionFor(category),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: canContinue ? _onContinue : null,
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

  Future<void> _onContinue() async {
    final state = ref.read(transferStateProvider);
    final notifier = ref.read(transferStateProvider.notifier);

    // Build the manifest from what the user actually picked. The receiver
    // renders Scan / Transfer / Done off this — it's the wire-level source
    // of truth for "what we agreed to transfer."
    final manifest = TransferManifest(
      senderDisplayName: 'OLD phone',
      categories: state.selectedCategories.toList()
        ..sort((a, b) =>
            kCategoryDisplayOrder.indexOf(a) -
            kCategoryDisplayOrder.indexOf(b)),
      counts: {
        for (final c in state.selectedCategories)
          c: state.categoryStatuses[c]?.count ?? 0,
      },
    );
    notifier.setSenderManifest(manifest);

    final session = state.pairedSession;
    if (session != null) {
      try {
        await session.sendFrame(manifest.toBytes());
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Send failed: $e')),
          );
        }
        return;
      }
    }
    if (mounted) context.go('/scan');
  }

  int _selectedItemTotal(TransferState state) {
    var total = 0;
    for (final c in state.selectedCategories) {
      // Disabled categories are never selectable, but defend in case a
      // future change re-introduces them in selectedCategories without
      // their probe running.
      if (!kEnabledCategories.contains(c)) continue;
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
    required this.enabled,
    required this.onToggle,
    required this.onRequestPermission,
  });

  final DataCategory category;
  final CategoryStatus? status;
  final bool selected;
  final bool probing;

  /// `false` for categories outside [kEnabledCategories]. Renders a
  /// grayed-out, untoggleable row with a "Coming soon" chip — same
  /// visual idiom we used in v0.0.1 when only SMS was wired. Code
  /// behind these categories stays in tree; flipping the constant
  /// brings them back without any other change.
  final bool enabled;
  final VoidCallback onToggle;
  final VoidCallback onRequestPermission;

  @override
  Widget build(BuildContext context) {
    final meta = _metaFor(category);
    final permissionDenied =
        status?.permissionState == PermissionState.denied;

    return CheckboxListTile(
      value: enabled && selected,
      // Null onChanged renders the checkbox in its disabled state.
      onChanged: enabled ? (_) => onToggle() : null,
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
    if (!enabled) {
      return const Chip(
        label: Text('Coming soon', style: TextStyle(fontSize: 11)),
        visualDensity: VisualDensity.compact,
      );
    }
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
    if (!enabled) {
      return const Text('Coming back in a future update');
    }
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
