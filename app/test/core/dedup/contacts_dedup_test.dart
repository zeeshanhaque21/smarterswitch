import 'package:flutter_test/flutter_test.dart';
import 'package:smarterswitch/core/dedup/contacts_dedup.dart';
import 'package:smarterswitch/core/model/contact.dart';

Contact _c({
  required String name,
  String? account,
  List<String> phones = const [],
  List<String> emails = const [],
}) =>
    Contact(
      displayName: name,
      sourceAccountType: account,
      phones: phones,
      emails: emails,
    );

void main() {
  group('matchKeysFor', () {
    test('phone, email, and name keys are distinct types', () {
      final c = _c(
        name: 'Alice',
        phones: ['+14155551212'],
        emails: ['alice@example.com'],
      );
      final keys = ContactsDedup.matchKeysFor(c);
      expect(keys, contains('phone:4155551212'));
      expect(keys, contains('email:alice@example.com'));
      expect(keys, contains('name:alice'));
    });

    test('email normalization is case-insensitive', () {
      final a = _c(name: 'Alice', emails: ['Alice@Example.com']);
      final b = _c(name: 'Alice', emails: ['alice@example.com']);
      expect(ContactsDedup.matchKeysFor(a),
          equals(ContactsDedup.matchKeysFor(b)));
    });

    test('empty fields produce empty keys, not blank strings', () {
      final c = _c(name: '', phones: ['', '   '], emails: ['']);
      // Phone normalization of empty/whitespace yields ""; we drop it.
      // Name-key for empty display name is also dropped.
      expect(ContactsDedup.matchKeysFor(c), isEmpty);
    });
  });

  group('ContactsDedup.diff', () {
    test('exact match (all keys overlap) silently dedups', () {
      final source = [
        _c(
          name: 'Alice Liddell',
          phones: ['+14155551212'],
          emails: ['alice@example.com'],
        ),
      ];
      final target = [
        _c(
          name: 'Alice Liddell',
          phones: ['(415) 555-1212'],
          emails: ['ALICE@example.com'],
        ),
      ];
      final report = ContactsDedup.diff(source: source, target: target);
      expect(report.exactDuplicates, 1);
      expect(report.newCount, 0);
      expect(report.conflictCount, 0);
    });

    test('partial match (one key shared) surfaces as conflict', () {
      final source = [
        _c(
          name: 'Alice Liddell',
          phones: ['+14155551212'],
          emails: ['alice@personal.com'],
        ),
      ];
      final target = [
        _c(
          // Different name
          name: 'Liddell A.',
          phones: ['+14155551212'],
          emails: ['alice@work.com'],
        ),
      ];
      final report = ContactsDedup.diff(source: source, target: target);
      expect(report.exactDuplicates, 0);
      expect(report.newCount, 0);
      expect(report.conflictCount, 1);
      final conflict = report.conflicts.single;
      expect(conflict.confidence, closeTo(1 / 3, 1e-9));
      expect(conflict.sharedKeys, contains('phone:4155551212'));
    });

    test('no shared keys → new contact', () {
      final source = [
        _c(
          name: 'Alice',
          phones: ['+14155551212'],
        ),
      ];
      final target = [
        _c(
          name: 'Bob',
          phones: ['+18005550199'],
        ),
      ];
      final report = ContactsDedup.diff(source: source, target: target);
      expect(report.newCount, 1);
      expect(report.conflictCount, 0);
      expect(report.exactDuplicates, 0);
    });

    test('Google-synced contacts are routed to delegatedToCloud, not matched', () {
      final source = [
        _c(
          name: 'Alice',
          account: 'com.google',
          phones: ['+14155551212'],
        ),
        _c(
          name: 'Bob',
          account: 'vnd.sec.contact.phone',
          phones: ['+18005550199'],
        ),
      ];
      final target = [
        _c(
          name: 'Bob',
          account: 'vnd.sec.contact.phone',
          phones: ['+18005550199'],
        ),
      ];
      final report = ContactsDedup.diff(source: source, target: target);
      expect(report.delegatedToCloud, hasLength(1));
      expect(report.delegatedToCloud.single.displayName, 'Alice');
      expect(report.exactDuplicates, 1, reason: 'Bob matches the local target');
      expect(report.newCount, 0);
    });

    test('contact with no identifying fields falls through to new', () {
      // Pathological case: a contact with no phone, no email, no name.
      // We can't match it; transferring it preserves data even though it
      // arrives as a (likely useless) blank entry the user will need to fix.
      final source = [_c(name: '')];
      final report = ContactsDedup.diff(source: source, target: const []);
      expect(report.newCount, 1);
      expect(report.conflictCount, 0);
    });

    test('best partial match is the one with highest confidence', () {
      final source = [
        _c(
          name: 'Alice',
          phones: ['+14155551212'],
          emails: ['alice@example.com'],
        ),
      ];
      final target = [
        // Confidence 1/3 — only name matches.
        _c(name: 'Alice'),
        // Confidence 2/3 — phone + email match. The diff should pick this one.
        _c(
          name: 'Different name',
          phones: ['+14155551212'],
          emails: ['alice@example.com'],
        ),
      ];
      final report = ContactsDedup.diff(source: source, target: target);
      expect(report.conflictCount, 1);
      expect(report.conflicts.single.confidence, closeTo(2 / 3, 1e-9));
      expect(report.conflicts.single.candidate.displayName, 'Different name');
    });
  });
}
