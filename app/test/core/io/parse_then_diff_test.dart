// End-to-end-ish: load two XML strings → SmsBackupXml.parse → SmsDedup.diff.
// Covers the same path the CLI harness exercises against real export files.

import 'package:flutter_test/flutter_test.dart';
import 'package:smarterswitch/core/dedup/sms_dedup.dart';
import 'package:smarterswitch/core/io/sms_backup_xml.dart';

const _sourceXml = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<smses count="3">
  <sms address="+14155551212" date="1700000000000" type="1" body="hello"/>
  <sms address="+14155551212" date="1700001000000" type="2" body="reply"/>
  <sms address="+14155551313" date="1700002000000" type="1" body="brand new contact"/>
</smses>
''';

const _targetXml = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<smses count="2">
  <!-- same as source[0] but with US country code dropped + 30s of jitter -->
  <sms address="(415) 555-1212" date="1700000030000" type="1" body="hello"/>
  <!-- something only on the target -->
  <sms address="+18005550199" date="1700009000000" type="1" body="spam"/>
</smses>
''';

void main() {
  test('parse-then-diff end-to-end on synthetic exports', () {
    final source = SmsBackupXml.parse(_sourceXml);
    final target = SmsBackupXml.parse(_targetXml);
    final report = SmsDedup.diff(source: source, target: target);

    expect(report.sourceTotal, 3);
    expect(report.targetTotal, 2);
    expect(report.duplicatesSkipped, 1,
        reason: 'source[0] should match target[0] after normalization');
    expect(report.newCount, 2,
        reason: 'the reply and the new-contact message are both new');
  });
}
