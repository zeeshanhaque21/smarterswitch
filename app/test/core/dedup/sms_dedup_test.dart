import 'package:flutter_test/flutter_test.dart';
import 'package:smarterswitch/core/dedup/sms_dedup.dart';
import 'package:smarterswitch/core/model/sms_record.dart';

SmsRecord _msg({
  required String address,
  required String body,
  required int tsMs,
  SmsType type = SmsType.inbox,
  int? threadId,
  List<String> mmsParts = const [],
}) =>
    SmsRecord(
      address: address,
      body: body,
      timestampMs: tsMs,
      type: type,
      threadId: threadId,
      mmsParts: mmsParts,
    );

void main() {
  group('SmsDedup.keyFor', () {
    test('identical records produce identical keys', () {
      final a = _msg(address: '+14155551212', body: 'hi', tsMs: 1700000000000);
      final b = _msg(address: '+14155551212', body: 'hi', tsMs: 1700000000000);
      expect(SmsDedup.keyFor(a), SmsDedup.keyFor(b));
    });

    test('phone-number formatting variations collapse', () {
      final variants = [
        '+14155551212',
        '+1 (415) 555-1212',
        '+1-415-555-1212',
        '+1.415.555.1212',
      ];
      final keys = variants
          .map((a) => SmsDedup.keyFor(_msg(address: a, body: 'hi', tsMs: 1700000000000)))
          .toSet();
      expect(keys, hasLength(1));
    });

    test('timestamp jitter within the same minute matches', () {
      final t = DateTime.utc(2026, 4, 29, 12, 0, 5).millisecondsSinceEpoch;
      final tPlus40s = DateTime.utc(2026, 4, 29, 12, 0, 45).millisecondsSinceEpoch;
      expect(
        SmsDedup.keyFor(_msg(address: '5551212', body: 'hi', tsMs: t)),
        SmsDedup.keyFor(_msg(address: '5551212', body: 'hi', tsMs: tPlus40s)),
      );
    });

    test('timestamps across a minute boundary do NOT match', () {
      final t = DateTime.utc(2026, 4, 29, 12, 0, 59).millisecondsSinceEpoch;
      final tNextMinute = DateTime.utc(2026, 4, 29, 12, 1, 0).millisecondsSinceEpoch;
      expect(
        SmsDedup.keyFor(_msg(address: '5551212', body: 'hi', tsMs: t)),
        isNot(equals(SmsDedup.keyFor(_msg(address: '5551212', body: 'hi', tsMs: tNextMinute)))),
      );
    });

    test('whitespace differences in body collapse', () {
      final a = _msg(address: '5551212', body: 'hello world', tsMs: 1700000000000);
      final b = _msg(address: '5551212', body: 'hello   world ', tsMs: 1700000000000);
      final c = _msg(address: '5551212', body: 'hello world\r\n', tsMs: 1700000000000);
      expect(SmsDedup.keyFor(a), SmsDedup.keyFor(b));
      expect(SmsDedup.keyFor(a), SmsDedup.keyFor(c));
    });

    test('case-sensitive body — different content produces different keys', () {
      final a = _msg(address: '5551212', body: 'Hello', tsMs: 1700000000000);
      final b = _msg(address: '5551212', body: 'hello', tsMs: 1700000000000);
      expect(SmsDedup.keyFor(a), isNot(equals(SmsDedup.keyFor(b))));
    });

    test('thread id and type do NOT affect the key', () {
      final a = _msg(
        address: '5551212',
        body: 'x',
        tsMs: 1700000000000,
        type: SmsType.inbox,
        threadId: 1,
      );
      final b = _msg(
        address: '5551212',
        body: 'x',
        tsMs: 1700000000000,
        type: SmsType.sent,
        threadId: 999,
      );
      expect(SmsDedup.keyFor(a), SmsDedup.keyFor(b));
    });

    test('MMS part hashes participate in the key, order-independent', () {
      final a = _msg(
        address: '5551212',
        body: '',
        tsMs: 1700000000000,
        mmsParts: ['hashA', 'hashB'],
      );
      final b = _msg(
        address: '5551212',
        body: '',
        tsMs: 1700000000000,
        mmsParts: ['hashB', 'hashA'],
      );
      final c = _msg(
        address: '5551212',
        body: '',
        tsMs: 1700000000000,
        mmsParts: ['hashB', 'hashC'],
      );
      expect(SmsDedup.keyFor(a), SmsDedup.keyFor(b));
      expect(SmsDedup.keyFor(a), isNot(equals(SmsDedup.keyFor(c))));
    });
  });

  group('SmsDedup.diff', () {
    test('reports correctly on a mixed batch', () {
      final source = [
        _msg(address: '+14155551212', body: 'hi', tsMs: 1700000000000),
        _msg(address: '+14155551212', body: 'are you there', tsMs: 1700000600000),
        _msg(address: '+14155551313', body: 'new contact', tsMs: 1700000700000),
      ];
      final target = [
        // Same as source[0] but timestamp jittered by 20s and address reformatted.
        _msg(address: '(415) 555-1212', body: 'hi', tsMs: 1700000000000 + 20000),
        // Unrelated noise on target side.
        _msg(address: '+18005550199', body: 'spam', tsMs: 1700000900000),
      ];
      final report = SmsDedup.diff(source: source, target: target);
      expect(report.duplicatesSkipped, 1);
      expect(report.newCount, 2);
      expect(report.sourceTotal, 3);
      expect(report.targetTotal, 2);
    });

    test('source-side duplicates are collapsed before transfer', () {
      final source = [
        _msg(address: '5551212', body: 'hi', tsMs: 1700000000000),
        _msg(address: '5551212', body: 'hi', tsMs: 1700000000000),
        _msg(address: '5551212', body: 'hi', tsMs: 1700000000000),
      ];
      final report = SmsDedup.diff(source: source, target: const []);
      expect(report.newCount, 1);
      expect(report.duplicatesSkipped, 0,
          reason: 'source-side dupes shouldn\'t be counted as target dupes');
    });

    test('empty source produces empty diff', () {
      final report = SmsDedup.diff(source: const [], target: const []);
      expect(report.newCount, 0);
      expect(report.duplicatesSkipped, 0);
    });
  });

  group('SmsDedup.isDuplicate', () {
    test('returns true for normalized match', () {
      final index = SmsDedup.indexOf([
        _msg(address: '+14155551212', body: 'hi', tsMs: 1700000000000),
      ]);
      final candidate = _msg(address: '415-555-1212', body: 'hi ', tsMs: 1700000005000);
      expect(SmsDedup.isDuplicate(index, candidate), isTrue);
    });
  });
}
