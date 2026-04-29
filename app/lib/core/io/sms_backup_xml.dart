import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import '../model/sms_record.dart';

/// Parses SMS Backup & Restore XML exports (the `.xml` produced by the
/// `com.riteshsahu.SMSBackupRestore` Android app — the de-facto standard
/// for SMS-only backups). Format reference:
///   https://www.synctech.com.au/sms-backup-restore/fields-in-xml-backup-files/
///
/// We recognize both `<sms>` and `<mms>` elements. MMS parts are hashed by
/// content (their `data` attribute) so the dedup engine can match attachment
/// payloads regardless of filename or order.
class SmsBackupXml {
  /// Parse a complete export file. Tolerates files whose root is `<smses ...>`
  /// (the canonical form) and also bare repeated `<sms .../>` (rare).
  static List<SmsRecord> parse(String xmlText) {
    final doc = XmlDocument.parse(xmlText);
    final records = <SmsRecord>[];

    for (final el in doc.findAllElements('sms')) {
      records.add(_smsFromElement(el));
    }
    for (final el in doc.findAllElements('mms')) {
      records.add(_mmsFromElement(el));
    }
    return records;
  }

  static SmsRecord _smsFromElement(XmlElement el) {
    return SmsRecord(
      address: el.getAttribute('address') ?? '',
      body: el.getAttribute('body') ?? '',
      timestampMs: int.tryParse(el.getAttribute('date') ?? '') ?? 0,
      type: _smsTypeFromAttr(el.getAttribute('type')),
      threadId: int.tryParse(el.getAttribute('thread_id') ?? ''),
    );
  }

  static SmsRecord _mmsFromElement(XmlElement mms) {
    final address = mms.getAttribute('address') ?? '';
    final date = int.tryParse(mms.getAttribute('date') ?? '') ?? 0;
    final type = _mmsTypeFromAttr(mms.getAttribute('msg_box'));
    final threadId = int.tryParse(mms.getAttribute('thread_id') ?? '');

    final partsEl = mms.getElement('parts');
    final partHashes = <String>[];
    String body = '';
    if (partsEl != null) {
      for (final part in partsEl.findElements('part')) {
        final ct = part.getAttribute('ct') ?? '';
        if (ct == 'text/plain') {
          body = part.getAttribute('text') ?? body;
        } else {
          final data = part.getAttribute('data');
          if (data != null && data.isNotEmpty) {
            // Hash the base64 payload bytes — content-addressed, regardless of
            // order or filename within the MMS.
            final bytes = base64.decode(data);
            partHashes.add(sha256.convert(bytes).toString());
          }
        }
      }
    }

    return SmsRecord(
      address: address,
      body: body,
      timestampMs: date,
      type: type,
      threadId: threadId,
      mmsParts: partHashes,
    );
  }

  /// SMS Backup & Restore writes the Android `Telephony.Sms.MESSAGE_TYPE_*`
  /// integer (1=inbox, 2=sent, etc.) into the `type` attribute.
  static SmsType _smsTypeFromAttr(String? raw) {
    final v = int.tryParse(raw ?? '') ?? 0;
    switch (v) {
      case 1:
        return SmsType.inbox;
      case 2:
        return SmsType.sent;
      case 3:
        return SmsType.draft;
      case 4:
        return SmsType.outbox;
      case 5:
        return SmsType.failed;
      case 6:
        return SmsType.queued;
      default:
        return SmsType.inbox;
    }
  }

  /// MMS uses `msg_box` instead of `type`: 1=inbox, 2=sent, 3=draft, 4=outbox.
  static SmsType _mmsTypeFromAttr(String? raw) {
    final v = int.tryParse(raw ?? '') ?? 0;
    switch (v) {
      case 1:
        return SmsType.inbox;
      case 2:
        return SmsType.sent;
      case 3:
        return SmsType.draft;
      case 4:
        return SmsType.outbox;
      default:
        return SmsType.inbox;
    }
  }
}
