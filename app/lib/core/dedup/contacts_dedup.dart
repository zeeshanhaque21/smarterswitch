import '../model/contact.dart';
import 'normalize.dart';

/// Multi-key contact matcher per ARCHITECTURE.md § core/dedup:
/// for non-Google-synced contacts, key on `(normalized_phone | email | full_name)`
/// with a confidence score; surface low-confidence matches to the user.
///
/// Each contact has a *set* of match-keys (one per phone, one per email, one
/// for the name). Two contacts "match" when their key sets intersect.
/// Confidence = `|shared| / max(|sourceKeys|, |targetKeys|)`. A confidence of
/// 1.0 means every key on both sides matches — safe to dedup silently. Lower
/// confidence (e.g. 0.5: same phone, different email) goes to conflict review.
///
/// Why max-of-the-two and not Jaccard (shared / union): with Jaccard, two
/// contacts that share their only common field score 0.5 even when one of
/// them has many extra fields the other can't possibly match. The product
/// question we're actually answering — "how confident are we these are the
/// same person?" — is better captured by "of the larger contact's keys, what
/// fraction overlap?". A 1-of-1 match is exact; 1-of-3 is fuzzy; 0-of-anything
/// is "different person."
class ContactsDedup {
  /// Build the set of match-keys for a contact.
  /// Each key is type-prefixed so a phone "5551212" cannot collide with an
  /// equally-formatted name fragment (unlikely, but the prefix makes it free).
  static Set<String> matchKeysFor(Contact c) {
    final keys = <String>{};
    for (final p in c.phones) {
      final norm = normalizeAddress(p);
      if (norm.isNotEmpty) keys.add('phone:$norm');
    }
    for (final e in c.emails) {
      final norm = normalizeEmail(e);
      if (norm.isNotEmpty) keys.add('email:$norm');
    }
    final name = normalizeTextCaseInsensitive(c.displayName);
    if (name.isNotEmpty) keys.add('name:$name');
    return keys;
  }

  /// Diff a sender batch against a receiver batch.
  ///
  /// Behavior per source contact:
  /// - confidence 1.0 → silent duplicate (counted)
  /// - 0 < confidence < 1.0 → conflict, surfaced for user review
  /// - confidence 0 → genuinely new, transferred
  ///
  /// Google-synced contacts on either side are *excluded* before matching;
  /// they're returned in [ContactsDedupReport.delegatedToCloud] as a hint to
  /// the UI ("these will be handled by Google account sync").
  static ContactsDedupReport diff({
    required List<Contact> source,
    required List<Contact> target,
  }) {
    final delegated =
        source.where((c) => c.isGoogleSynced).toList(growable: false);
    final localSource =
        source.where((c) => !c.isGoogleSynced).toList(growable: false);
    final localTarget =
        target.where((c) => !c.isGoogleSynced).toList(growable: false);

    // Pre-compute target key sets once.
    final targetKeySets = [
      for (final t in localTarget) matchKeysFor(t),
    ];

    final newContacts = <Contact>[];
    final conflicts = <ContactConflict>[];
    var exactDuplicates = 0;

    for (final s in localSource) {
      final sKeys = matchKeysFor(s);
      if (sKeys.isEmpty) {
        // No identifying fields at all — can't match anything. Treat as new
        // (so the user doesn't lose data) but the receiver-side writer should
        // flag these for manual review later.
        newContacts.add(s);
        continue;
      }

      ContactConflict? bestPartial;
      var exactFound = false;

      for (var i = 0; i < localTarget.length && !exactFound; i++) {
        final shared = sKeys.intersection(targetKeySets[i]);
        if (shared.isEmpty) continue;
        final maxKeys = sKeys.length > targetKeySets[i].length
            ? sKeys.length
            : targetKeySets[i].length;
        final confidence = shared.length / maxKeys;
        if (confidence >= 1.0 - 1e-9) {
          exactFound = true;
          exactDuplicates += 1;
          break;
        }
        if (bestPartial == null || confidence > bestPartial.confidence) {
          bestPartial = ContactConflict(
            source: s,
            candidate: localTarget[i],
            confidence: confidence,
            sharedKeys: shared,
          );
        }
      }

      if (exactFound) continue;
      if (bestPartial != null) {
        conflicts.add(bestPartial);
      } else {
        newContacts.add(s);
      }
    }

    return ContactsDedupReport(
      newContacts: List.unmodifiable(newContacts),
      conflicts: List.unmodifiable(conflicts),
      delegatedToCloud: List.unmodifiable(delegated),
      exactDuplicates: exactDuplicates,
      sourceTotal: source.length,
      targetTotal: target.length,
    );
  }
}

class ContactConflict {
  const ContactConflict({
    required this.source,
    required this.candidate,
    required this.confidence,
    required this.sharedKeys,
  });

  final Contact source;
  final Contact candidate;

  /// 0..1, exclusive of both endpoints. 1.0 means exact dedup (handled
  /// elsewhere); 0.0 means no overlap (handled elsewhere).
  final double confidence;

  /// The intersection — `phone:4155551212`, `email:alice@example.com`, etc.
  /// Surfaced verbatim in the conflict review UI so the user sees why we
  /// suspect a match.
  final Set<String> sharedKeys;
}

class ContactsDedupReport {
  const ContactsDedupReport({
    required this.newContacts,
    required this.conflicts,
    required this.delegatedToCloud,
    required this.exactDuplicates,
    required this.sourceTotal,
    required this.targetTotal,
  });

  final List<Contact> newContacts;

  /// Partial matches the user must resolve before transfer. The Done screen
  /// reports how many got resolved.
  final List<ContactConflict> conflicts;

  /// Google-account contacts that we don't transfer at all — Google's account
  /// sync handles them cloud-side.
  final List<Contact> delegatedToCloud;

  final int exactDuplicates;
  final int sourceTotal;
  final int targetTotal;

  int get newCount => newContacts.length;
  int get conflictCount => conflicts.length;
}
