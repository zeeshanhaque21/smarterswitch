import 'package:flutter/foundation.dart';

import 'transfer_state.dart';

enum CategoryPhase {
  queued,
  preparing,
  streaming,
  done,
}

@immutable
class TransferProgress {
  const TransferProgress({
    this.processed = const {},
    this.sent = const {},
    this.written = const {},
    this.skipped = const {},
    this.phases = const {},
    this.framesSeen = 0,
    this.lastFrameKind = '—',
    this.frameError,
    this.flowState = 'init',
    this.done = false,
    this.error,
    this.hashed = 0,
    this.hashTotal = 0,
    this.photosSkippedPreflight = 0,
  });

  final Map<DataCategory, int> processed;
  final Map<DataCategory, int> sent;
  final Map<DataCategory, int> written;
  final Map<DataCategory, int> skipped;
  final Map<DataCategory, CategoryPhase> phases;
  final int framesSeen;
  final String lastFrameKind;
  final String? frameError;
  final String flowState;
  final bool done;
  final String? error;
  final int hashed;
  final int hashTotal;
  final int photosSkippedPreflight;

  TransferProgress copyWith({
    Map<DataCategory, int>? processed,
    Map<DataCategory, int>? sent,
    Map<DataCategory, int>? written,
    Map<DataCategory, int>? skipped,
    Map<DataCategory, CategoryPhase>? phases,
    int? framesSeen,
    String? lastFrameKind,
    String? frameError,
    String? flowState,
    bool? done,
    String? error,
    int? hashed,
    int? hashTotal,
    int? photosSkippedPreflight,
  }) {
    return TransferProgress(
      processed: processed ?? this.processed,
      sent: sent ?? this.sent,
      written: written ?? this.written,
      skipped: skipped ?? this.skipped,
      phases: phases ?? this.phases,
      framesSeen: framesSeen ?? this.framesSeen,
      lastFrameKind: lastFrameKind ?? this.lastFrameKind,
      frameError: frameError ?? this.frameError,
      flowState: flowState ?? this.flowState,
      done: done ?? this.done,
      error: error ?? this.error,
      hashed: hashed ?? this.hashed,
      hashTotal: hashTotal ?? this.hashTotal,
      photosSkippedPreflight: photosSkippedPreflight ?? this.photosSkippedPreflight,
    );
  }
}
