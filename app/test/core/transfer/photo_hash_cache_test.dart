import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smarterswitch/core/transfer/photo_hash_cache.dart';

void main() {
  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('smarterswitch_phc_');
  });
  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('empty on first open of a fresh dir', () async {
    final cache = await PhotoHashCache.open(tempDir.path);
    expect(cache.size, 0);
    expect(cache.get('uri', byteSize: 100, modifiedAtMs: 1), isNull);
  });

  test('put + get round-trips matching key', () async {
    final cache = await PhotoHashCache.open(tempDir.path);
    cache.put('content://1', byteSize: 100, modifiedAtMs: 200, sha256: 'abc');
    final hit = cache.get('content://1', byteSize: 100, modifiedAtMs: 200);
    expect(hit, isNotNull);
    expect(hit!.sha256, 'abc');
    expect(hit.pHash, isNull);
  });

  test('cache miss when byteSize differs', () async {
    final cache = await PhotoHashCache.open(tempDir.path);
    cache.put('content://1', byteSize: 100, modifiedAtMs: 200, sha256: 'abc');
    expect(
      cache.get('content://1', byteSize: 101, modifiedAtMs: 200),
      isNull,
    );
  });

  test('cache miss when modifiedAtMs differs', () async {
    final cache = await PhotoHashCache.open(tempDir.path);
    cache.put('content://1', byteSize: 100, modifiedAtMs: 200, sha256: 'abc');
    expect(
      cache.get('content://1', byteSize: 100, modifiedAtMs: 999),
      isNull,
    );
  });

  test('save + reopen persists entries', () async {
    final first = await PhotoHashCache.open(tempDir.path);
    first.put('content://1',
        byteSize: 100, modifiedAtMs: 200, sha256: 'abc', pHash: 0xdeadbeef);
    first.put('content://2',
        byteSize: 50, modifiedAtMs: 300, sha256: 'def');
    await first.save();

    final second = await PhotoHashCache.open(tempDir.path);
    expect(second.size, 2);
    final hit1 = second.get('content://1', byteSize: 100, modifiedAtMs: 200);
    expect(hit1?.sha256, 'abc');
    expect(hit1?.pHash, 0xdeadbeef);
    final hit2 = second.get('content://2', byteSize: 50, modifiedAtMs: 300);
    expect(hit2?.sha256, 'def');
    expect(hit2?.pHash, isNull);
  });

  test('retainOnly drops missing URIs', () async {
    final cache = await PhotoHashCache.open(tempDir.path);
    cache.put('a', byteSize: 1, modifiedAtMs: 1, sha256: 'a');
    cache.put('b', byteSize: 1, modifiedAtMs: 1, sha256: 'b');
    cache.put('c', byteSize: 1, modifiedAtMs: 1, sha256: 'c');
    cache.retainOnly({'a', 'c'});
    expect(cache.size, 2);
    expect(cache.get('b', byteSize: 1, modifiedAtMs: 1), isNull);
    expect(cache.get('a', byteSize: 1, modifiedAtMs: 1)?.sha256, 'a');
    expect(cache.get('c', byteSize: 1, modifiedAtMs: 1)?.sha256, 'c');
  });

  test('corrupted cache file produces an empty cache instead of crashing',
      () async {
    final f = File('${tempDir.path}/photo_hash_cache.json');
    await f.writeAsString('{not valid json');
    final cache = await PhotoHashCache.open(tempDir.path);
    expect(cache.size, 0);
  });
}
