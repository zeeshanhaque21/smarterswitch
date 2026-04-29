import 'package:flutter/foundation.dart';

import '../core/dedup/contacts_dedup.dart';
import '../core/dedup/photos_dedup.dart';

/// A row in the Conflict Review screen. Wraps the per-category conflict types
/// so the screen can render contacts + photos side-by-side without a giant
/// switch in the widget tree.
@immutable
sealed class Conflict {
  const Conflict();

  /// What the resolution UI should call this kind of conflict.
  String get kindLabel;
}

@immutable
class ContactConflictItem extends Conflict {
  const ContactConflictItem(this.inner);
  final ContactConflict inner;
  @override
  String get kindLabel => 'Contact';
}

@immutable
class PhotoConflictItem extends Conflict {
  const PhotoConflictItem(this.inner);
  final PhotoConflict inner;
  @override
  String get kindLabel => 'Photo';
}

enum ConflictDecision {
  /// Default: bring both records over so the user loses nothing. The
  /// receiver may end up with a near-duplicate but at least nothing is lost.
  keepBoth,

  /// Skip the source record; keep what the receiver already has.
  keepTarget,

  /// Overwrite the receiver's record with the source.
  keepSource,
}
