import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Direction the user picks on the Pair screen. The same app binary is both
/// sender and receiver — only the role differs at runtime.
enum DeviceRole { sender, receiver, unset }

/// Categories the user can choose to transfer. Phase 1 only meaningfully
/// supports SMS; the rest are present in the UI so the flow looks complete and
/// the wiring is in place for Phase 2.
enum DataCategory { sms, callLog, contacts, photos, calendar }

@immutable
class TransferState {
  const TransferState({
    this.role = DeviceRole.unset,
    this.peerName,
    this.selectedCategories = const {DataCategory.sms},
    this.scanResult,
  });

  final DeviceRole role;
  final String? peerName;
  final Set<DataCategory> selectedCategories;
  final ScanResult? scanResult;

  TransferState copyWith({
    DeviceRole? role,
    String? peerName,
    Set<DataCategory>? selectedCategories,
    ScanResult? scanResult,
  }) =>
      TransferState(
        role: role ?? this.role,
        peerName: peerName ?? this.peerName,
        selectedCategories: selectedCategories ?? this.selectedCategories,
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
  TransferStateNotifier() : super(const TransferState());

  void setRole(DeviceRole role) => state = state.copyWith(role: role);

  void toggleCategory(DataCategory category) {
    final next = Set<DataCategory>.from(state.selectedCategories);
    if (!next.add(category)) next.remove(category);
    state = state.copyWith(selectedCategories: next);
  }

  void setScanResult(ScanResult result) =>
      state = state.copyWith(scanResult: result);
}

final transferStateProvider =
    StateNotifierProvider<TransferStateNotifier, TransferState>(
  (ref) => TransferStateNotifier(),
);
