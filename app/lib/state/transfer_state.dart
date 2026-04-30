import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/transfer/manifest.dart';
import '../core/transfer/transport.dart';
import '../platform/category_counts.dart';
import 'conflicts.dart';

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
    this.conflicts = const [],
    this.conflictDecisions = const {},
    this.pairedSession,
    this.transportKind,
    this.senderManifest,
    this.writtenByCategory = const {},
    this.skippedByCategory = const {},
  });

  final DeviceRole role;
  final String? peerName;

  /// Live session once Pair completes. Held in state so Scan/Transfer/Done
  /// can read frames from it. Null until Pair succeeds.
  final PairedSession? pairedSession;

  /// Human-readable label for the transport that paired ("Local Wi-Fi" /
  /// "Wi-Fi Direct" / "USB-C"). Surfaced in headers so the user knows what
  /// path they're on.
  final String? transportKind;

  /// On the receiver: the manifest sent by the sender after pair, declaring
  /// what's about to be transferred. Null until the first framed message
  /// from the peer arrives. On the sender: the manifest the local user
  /// just sent (we keep a copy so Scan/Transfer can render the same
  /// numbers on both phones).
  final TransferManifest? senderManifest;

  /// Receiver-side tally of records actually written per category, after
  /// dedup. Surfaced on the Done screen so the user knows what really
  /// landed.
  final Map<DataCategory, int> writtenByCategory;

  /// Receiver-side tally of records skipped as duplicates per category.
  final Map<DataCategory, int> skippedByCategory;
  final Set<DataCategory> selectedCategories;

  /// Per-category local probe — counts, permission state, byte estimates.
  /// Empty until `probeAllCategoryCounts()` runs.
  final Map<DataCategory, CategoryStatus> categoryStatuses;

  /// Result of the manifest exchange with the peer. Phase-2; null until then.
  final ScanResult? scanResult;

  /// Fuzzy-match conflicts surfaced by the dedup engines for the user to
  /// resolve. Populated after the manifest exchange; consumed by the
  /// Conflict Review screen.
  final List<Conflict> conflicts;

  /// User decisions per conflict, keyed by index into [conflicts]. Defaults
  /// to [ConflictDecision.keepBoth] for any unresolved entry.
  final Map<int, ConflictDecision> conflictDecisions;

  TransferState copyWith({
    DeviceRole? role,
    String? peerName,
    Set<DataCategory>? selectedCategories,
    Map<DataCategory, CategoryStatus>? categoryStatuses,
    ScanResult? scanResult,
    List<Conflict>? conflicts,
    Map<int, ConflictDecision>? conflictDecisions,
    PairedSession? pairedSession,
    String? transportKind,
    TransferManifest? senderManifest,
    Map<DataCategory, int>? writtenByCategory,
    Map<DataCategory, int>? skippedByCategory,
  }) =>
      TransferState(
        role: role ?? this.role,
        peerName: peerName ?? this.peerName,
        selectedCategories: selectedCategories ?? this.selectedCategories,
        categoryStatuses: categoryStatuses ?? this.categoryStatuses,
        scanResult: scanResult ?? this.scanResult,
        conflicts: conflicts ?? this.conflicts,
        conflictDecisions: conflictDecisions ?? this.conflictDecisions,
        pairedSession: pairedSession ?? this.pairedSession,
        transportKind: transportKind ?? this.transportKind,
        senderManifest: senderManifest ?? this.senderManifest,
        writtenByCategory: writtenByCategory ?? this.writtenByCategory,
        skippedByCategory: skippedByCategory ?? this.skippedByCategory,
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

  void setConflicts(List<Conflict> conflicts) {
    state = state.copyWith(
      conflicts: conflicts,
      conflictDecisions: const {},
    );
  }

  void resolveConflict(int index, ConflictDecision decision) {
    final next = Map<int, ConflictDecision>.from(state.conflictDecisions);
    next[index] = decision;
    state = state.copyWith(conflictDecisions: next);
  }

  void setPairedSession({
    required PairedSession session,
    required String transportKind,
    required DeviceRole role,
  }) {
    state = state.copyWith(
      pairedSession: session,
      transportKind: transportKind,
      role: role,
      peerName: session.peerDisplayName,
    );
  }

  void clearPairedSession() {
    state = TransferState(
      role: state.role,
      // Drop the session and counts so a new pair starts cleanly.
    );
  }

  void setSenderManifest(TransferManifest manifest) {
    state = state.copyWith(senderManifest: manifest);
  }

  void setTransferTallies(
    Map<DataCategory, int> written,
    Map<DataCategory, int> skipped,
  ) {
    state = state.copyWith(
      writtenByCategory: Map<DataCategory, int>.from(written),
      skippedByCategory: Map<DataCategory, int>.from(skipped),
    );
  }
}

final transferStateProvider =
    StateNotifierProvider<TransferStateNotifier, TransferState>(
  (ref) => TransferStateNotifier(),
);
