import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smarterswitch/core/io/sms_backup_xml.dart';
import 'package:smarterswitch/core/model/sms_record.dart';

const _smsXml = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<smses count="2">
  <sms protocol="0"
       address="+14155551212"
       date="1700000000000"
       type="1"
       body="hello world"
       thread_id="42"
       readable_date="Nov 14, 2023" />
  <sms protocol="0"
       address="(415) 555-1313"
       date="1700001000000"
       type="2"
       body="reply"
       thread_id="43"
       readable_date="Nov 14, 2023" />
</smses>
''';

void main() {
  group('SmsBackupXml.parse', () {
    test('parses sms elements with the expected fields', () {
      final records = SmsBackupXml.parse(_smsXml);
      expect(records, hasLength(2));

      final first = records[0];
      expect(first.address, '+14155551212');
      expect(first.body, 'hello world');
      expect(first.timestampMs, 1700000000000);
      expect(first.type, SmsType.inbox);
      expect(first.threadId, 42);

      final second = records[1];
      expect(second.address, '(415) 555-1313');
      expect(second.type, SmsType.sent);
      expect(second.threadId, 43);
    });

    test('parses MMS with text + binary parts and hashes binary content', () {
      // Two non-text parts containing distinct payloads, in deliberately weird order.
      final imageA = base64.encode(List.generate(16, (i) => i));
      final imageB = base64.encode(List.generate(16, (i) => 255 - i));
      final mmsXml = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<smses count="1">
  <mms address="+14155551212" date="1700000000000" msg_box="1" thread_id="7">
    <parts>
      <part seq="0" ct="text/plain" text="see attached" />
      <part seq="1" ct="image/jpeg" data="$imageA" />
      <part seq="2" ct="image/jpeg" data="$imageB" />
    </parts>
  </mms>
</smses>
''';
      final records = SmsBackupXml.parse(mmsXml);
      expect(records, hasLength(1));
      expect(records[0].body, 'see attached');
      expect(records[0].mmsParts, hasLength(2));
      // Each hash is hex sha256 → 64 chars.
      expect(records[0].mmsParts.first.length, 64);
    });

    test('skips elements that are not sms or mms', () {
      const xml = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<smses count="1">
  <metadata version="2"/>
  <sms address="5551212" date="1700000000000" type="1" body="hi"/>
</smses>
''';
      final records = SmsBackupXml.parse(xml);
      expect(records, hasLength(1));
      expect(records.single.body, 'hi');
    });
  });
}
