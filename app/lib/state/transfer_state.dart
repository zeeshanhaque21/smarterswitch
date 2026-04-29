import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/category_counts.dart';

/// Direction the user picks on the Pair screen. The same app binary is both
/// sender and receiver — only the role differs at runtime.
enum DeviceRole { sender, receiver, unset }

/// Categories the user can choose to transfer.
enum DataCategory { sms, callLog, contacts, photos, calendar }

/// Display order for the Select screen — driven from a single source so the
/// list stays consistent across screens.
const kCategoryDisplayOrder = <DataCategory>[
  DataCategory.sms,
  DataCategory.callLog,
  DataCategory.contacts,
  DataCategory.photos,
  DataCategory.calendar,
];

enum PermissionState { notRequested, granted, denied, restricted }

@immutable
class CategoryStatus {
  const CategoryStatus({
    required this.category,
    required this.permissionState,
    this.count,
    this.estimatedBytes,
  });

  final DataCategory category;
  final PermissionState permissionState;

  /// Local row count, or null if not yet probed (or probe failed).
  final int? count;

  /// Photos/videos only — sum of file sizes in bytes. Null for other
  /// categories where the byte total isn't a meaningful pre-transfer signal.
  final int? estimatedBytes;

  CategoryStatus copyWith({
    PermissionState? permissionState,
    int? count,
    int? estimatedBytes,
  }) =>
      CategoryStatus(
        category: category,
        permissionState: permissionState ?? this.permissionState,
        count: count ?? this.count,
        estimatedBytes: estimatedBytes ?? this.estimatedBytes,
      );
}

@immutable
class TransferState {
  const TransferState({
    this.role = DeviceRole.unset,
    this.peerName,
    this.selectedCategories = const {
      DataCategory.sms,
      DataCategory.callLog,
      DataCategory.contacts,
      DataCategory.photos,
      DataCategory.calendar,
    },
    this.scanResult,
    this.categoryStatuses = const {},
  });

  final DeviceRole role;
  final String? peerName;
  final Set<DataCategory> selectedCategories;

  /// Per-category local probe — counts, permission state, byte estimates.
  /// Empty until `probeAllCategoryCounts()` runs.
  final Map<DataCategory, CategoryStatus> categoryStatuses;

  /// Result of the manifest exchange with the peer. Phase-2; null until then.
  final ScanResult? scanResult;

  TransferState copyWith({
    DeviceRole? role,
    String? peerName,
    Set<DataCategory>? selectedCategories,
    Map<DataCategory, CategoryStatus>? categoryStatuses,
    ScanResult? scanResult,
  }) =>
      TransferState(
        role: role ?? this.role,
        peerName: peerName ?? this.peerName,
        selectedCategories: selectedCategories ?? this.selectedCategories,
        categoryStatuses: categoryStatuses ?? this.categoryStatuses,
        scanResult: scanResult ?? this.scanResult,
      );
}

@immutable
class ScanResult {
  const ScanResult({
    required this.sourceTotal,
    required this.targetTotal,
    required this.duplicates,
    required this.newRecords,
  });

  final int sourceTotal;
  final int targetTotal;
  final int duplicates;
  final int newRecords;
}

class TransferStateNotifier extends StateNotifier<TransferState> {
  TransferStateNotifier({CategoryProbe? probe})
      : _probe = probe ?? CategoryProbe(),
        super(const TransferState());

  final CategoryProbe _probe;

  void setRole(DeviceRole role) => state = state.copyWith(role: role);

  void toggleCategory(DataCategory category) {
    final next = Set<DataCategory>.from(state.selectedCategories);
    if (!next.add(category)) next.remove(category);
    state = state.copyWith(selectedCategories: next);
  }

  void setAllCategories(bool selected) {
    state = state.copyWith(
      selectedCategories: selected
          ? Set<DataCategory>.from(kCategoryDisplayOrder)
          : <DataCategory>{},
    );
  }

  /// Fan out to all five category channels in parallel and store the result.
  /// Idempotent — safe to call again after the user grants a new permission.
  Future<void> probeAllCategoryCounts() async {
    final statuses = await _probe.probeAll();
    state = state.copyWith(categoryStatuses: statuses);
  }

  void setScanResult(ScanResult result) =>
      state = state.copyWith(scanResult: result);
}

final transferStateProvider =
    StateNotifierProvider<TransferStateNotifier, TransferState>(
  (ref) => TransferStateNotifier(),
);
