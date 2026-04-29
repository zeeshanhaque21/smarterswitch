/// A single contact, normalized into a platform-agnostic form before being
/// fed to the contacts dedup engine.
///
/// Note on Google-synced contacts: Google Contacts already merges Google-account
/// contacts cloud-side as part of normal account sync. Matching them again on
/// the receiver would either be a no-op (if both phones see the synced state)
/// or harmful (if one side hasn't synced yet, we'd merge stale data). The
/// matcher in `contacts_dedup.dart` exposes a filter helper so callers can
/// route Google-synced contacts to a "delegated to cloud sync" report channel
/// instead of running them through the multi-key matcher.
class Contact {
  const Contact({
    required this.displayName,
    this.sourceAccountType,
    this.givenName,
    this.familyName,
    this.phones = const [],
    this.emails = const [],
    this.organization,
  });

  /// Account type as reported by `ContactsContract.RawContacts.ACCOUNT_TYPE`.
  /// Examples: `com.google`, `vnd.sec.contact.phone` (Samsung local),
  /// `com.android.contacts.sim`. Used to identify the Google-synced subset.
  final String? sourceAccountType;

  /// User-visible "Display Name" (e.g. "Alice Liddell").
  final String displayName;

  final String? givenName;
  final String? familyName;

  final List<String> phones;
  final List<String> emails;

  final String? organization;

  bool get isGoogleSynced =>
      sourceAccountType != null && sourceAccountType!.startsWith('com.google');
}
