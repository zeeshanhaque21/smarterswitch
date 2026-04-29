import 'package:flutter_test/flutter_test.dart';
import 'package:smarterswitch/core/dedup/call_log_dedup.dart';
import 'package:smarterswitch/core/model/call_log_record.dart';

CallLogRecord _call({
  required String number,
  required int tsMs,
  required int duration,
  required CallDirection direction,
  String? cachedName,
}) =>
    CallLogRecord(
      number: number,
      timestampMs: tsMs,
      durationSeconds: duration,
      direction: direction,
      cachedName: cachedName,
    );

void main() {
  group('CallLogDedup.keyFor', () {
    test('identical calls produce identical keys', () {
      final a = _call(
        number: '+14155551212',
        tsMs: 1700000000000,
        duration: 42,
        direction: CallDirection.outgoing,
      );
      final b = _call(
        number: '+14155551212',
        tsMs: 1700000000000,
        duration: 42,
        direction: CallDirection.outgoing,
      );
      expect(CallLogDedup.keyFor(a), CallLogDedup.keyFor(b));
    });

    test('phone-number formatting variations collapse', () {
      final a = _call(
        number: '+14155551212',
        tsMs: 1700000000000,
        duration: 30,
        direction: CallDirection.incoming,
      );
      final b = _call(
        number: '(415) 555-1212',
        tsMs: 1700000000000,
        duration: 30,
        direction: CallDirection.incoming,
      );
      expect(CallLogDedup.keyFor(a), CallLogDedup.keyFor(b));
    });

    test('different durations on the same minute do NOT match', () {
      final shortHangup = _call(
        number: '5551212',
        tsMs: 1700000000000,
        duration: 5,
        direction: CallDirection.outgoing,
      );
      final realCall = _call(
        number: '5551212',
        tsMs: 1700000000000,
        duration: 180,
        direction: CallDirection.outgoing,
      );
      expect(
        CallLogDedup.keyFor(shortHangup),
        isNot(equals(CallLogDedup.keyFor(realCall))),
      );
    });

    test('different directions do NOT match', () {
      final outgoing = _call(
        number: '5551212',
        tsMs: 1700000000000,
        duration: 60,
        direction: CallDirection.outgoing,
      );
      final incoming = _call(
        number: '5551212',
        tsMs: 1700000000000,
        duration: 60,
        direction: CallDirection.incoming,
      );
      expect(
        CallLogDedup.keyFor(outgoing),
        isNot(equals(CallLogDedup.keyFor(incoming))),
      );
    });

    test('cachedName does NOT affect the key', () {
      final s23 = _call(
        number: '5551212',
        tsMs: 1700000000000,
        duration: 60,
        direction: CallDirection.incoming,
        cachedName: 'Mom',
      );
      final pixel = _call(
        number: '5551212',
        tsMs: 1700000000000,
        duration: 60,
        direction: CallDirection.incoming,
        cachedName: 'Mother',
      );
      expect(CallLogDedup.keyFor(s23), CallLogDedup.keyFor(pixel));
    });

    test('timestamp jitter within the same minute matches', () {
      final t = DateTime.utc(2026, 4, 29, 12, 0, 5).millisecondsSinceEpoch;
      final tPlus40s = DateTime.utc(2026, 4, 29, 12, 0, 45).millisecondsSinceEpoch;
      expect(
        CallLogDedup.keyFor(_call(
          number: '5551212',
          tsMs: t,
          duration: 60,
          direction: CallDirection.incoming,
        )),
        CallLogDedup.keyFor(_call(
          number: '5551212',
          tsMs: tPlus40s,
          duration: 60,
          direction: CallDirection.incoming,
        )),
      );
    });
  });

  group('CallLogDedup.diff', () {
    test('reports correctly on a mixed batch', () {
      final source = [
        _call(
          number: '+14155551212',
          tsMs: 1700000000000,
          duration: 60,
          direction: CallDirection.outgoing,
        ),
        _call(
          number: '+14155551313',
          tsMs: 1700001000000,
          duration: 0,
          direction: CallDirection.missed,
        ),
      ];
      final target = [
        // Same as source[0] but jittered + reformatted address.
        _call(
          number: '(415) 555-1212',
          tsMs: 1700000000000 + 25000,
          duration: 60,
          direction: CallDirection.outgoing,
        ),
      ];
      final report = CallLogDedup.diff(source: source, target: target);
      expect(report.duplicatesSkipped, 1);
      expect(report.newCount, 1);
    });

    test('source-side duplicates are collapsed before transfer', () {
      final source = [
        _call(
          number: '5551212',
          tsMs: 1700000000000,
          duration: 60,
          direction: CallDirection.incoming,
        ),
        _call(
          number: '5551212',
          tsMs: 1700000000000,
          duration: 60,
          direction: CallDirection.incoming,
        ),
      ];
      final report = CallLogDedup.diff(source: source, target: const []);
      expect(report.newCount, 1);
      expect(report.duplicatesSkipped, 0);
    });
  });
}
