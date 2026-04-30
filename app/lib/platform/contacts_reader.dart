import 'package:flutter/services.dart';

import '../core/model/contact.dart';

/// Dart wrapper for `smarterswitch/contacts` — read + count + write.
class ContactsReader {
  ContactsReader({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('smarterswitch/contacts');
  final MethodChannel _channel;

  Future<bool> hasReadPermission() async =>
      (await _channel.invokeMethod<bool>('hasReadPermission')) ?? false;

  Future<bool> hasWritePermission() async =>
      (await _channel.invokeMethod<bool>('hasWritePermission')) ?? false;

  Future<int> count() async =>
      (await _channel.invokeMethod<num>('count'))?.toInt() ?? 0;

  Future<List<Contact>> readAll() async {
    final raw = await _channel.invokeMethod<List<Object?>>('readAll');
    if (raw == null) return const [];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map(_fromMap)
        .toList(growable: false);
  }

  Future<int> writeAll(List<Contact> contacts) async {
    final args = contacts.map(_toMap).toList(growable: false);
    final n = await _channel.invokeMethod<num>('writeAll', args);
    return n?.toInt() ?? 0;
  }

  static Contact _fromMap(Map<Object?, Object?> m) => Contact(
        displayName: (m['displayName'] as String?) ?? '',
        sourceAccountType: m['sourceAccountType'] as String?,
        phones: ((m['phones'] as List<dynamic>?) ?? const [])
            .cast<String>()
            .toList(growable: false),
        emails: ((m['emails'] as List<dynamic>?) ?? const [])
            .cast<String>()
            .toList(growable: false),
      );

  static Map<String, Object?> _toMap(Contact c) => {
        'displayName': c.displayName,
        'sourceAccountType': c.sourceAccountType,
        'phones': c.phones,
        'emails': c.emails,
      };
}
