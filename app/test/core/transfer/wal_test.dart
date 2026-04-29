import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smarterswitch/core/transfer/wal.dart';

late Directory _tempDir;

String _path(String name) => '${_tempDir.path}/$name';

void main() {
  setUp(() async {
    _tempDir = await Directory.systemTemp.createTemp('smarterswitch_wal_');
  });

  tearDown(() async {
    if (await _tempDir.exists()) {
      await _tempDir.delete(recursive: true);
    }
  });

  group('CategoryWal', () {
    test('starts at watermark 0 for a fresh file', () async {
      final wal = await CategoryWal.open(_path('sms.wal'));
      expect(wal.watermark, 0);
      await wal.close();
    });

    test('ack monotonically advances the watermark', () async {
      final wal = await CategoryWal.open(_path('sms.wal'));
      await wal.ack(1);
      expect(wal.watermark, 1);
      await wal.ack(2);
      expect(wal.watermark, 2);
      await wal.ack(50);
      expect(wal.watermark, 50);
      await wal.close();
    });

    test('ack regression throws', () async {
      final wal = await CategoryWal.open(_path('sms.wal'));
      await wal.ack(5);
      expect(() => wal.ack(5), throwsStateError);
      expect(() => wal.ack(3), throwsStateError);
      await wal.close();
    });

    test('reopen recovers the highest watermark', () async {
      final p = _path('sms.wal');
      final first = await CategoryWal.open(p);
      await first.ack(1);
      await first.ack(2);
      await first.ack(7);
      await first.close();

      final second = await CategoryWal.open(p);
      expect(second.watermark, 7);
      await second.close();
    });

    test('reopen tolerates a partial trailing line', () async {
      final p = _path('photos.wal');
      final first = await CategoryWal.open(p);
      await first.ack(10);
      await first.ack(20);
      await first.close();

      // Simulate a crash mid-write: append a partial line that doesn't
      // parse. Recovery should ignore it and still surface 20 as the
      // watermark.
      await File(p).writeAsString('garbage', mode: FileMode.append);

      final second = await CategoryWal.open(p);
      expect(second.watermark, 20);
      await second.close();
    });

    test('reset clears the watermark and removes the file', () async {
      final p = _path('contacts.wal');
      final wal = await CategoryWal.open(p);
      await wal.ack(99);
      await wal.reset();
      expect(wal.watermark, 0);
      await wal.close();

      final reopened = await CategoryWal.open(p);
      expect(reopened.watermark, 0);
      await reopened.close();
    });
  });
}
