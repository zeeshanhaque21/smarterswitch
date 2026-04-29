import 'package:flutter_test/flutter_test.dart';
import 'package:smarterswitch/core/dedup/photos_dedup.dart';
import 'package:smarterswitch/core/model/media_record.dart';

MediaRecord _img({
  required String uri,
  required String sha256Hex,
  int? pHash,
  int byteSize = 1024,
}) =>
    MediaRecord(
      uri: uri,
      fileName: uri.split('/').last,
      byteSize: byteSize,
      kind: MediaKind.image,
      sha256Hex: sha256Hex,
      pHash: pHash,
    );

void main() {
  group('PhotosDedup.hammingDistance64', () {
    test('identical inputs → 0', () {
      expect(PhotosDedup.hammingDistance64(0xdeadbeefcafebabe, 0xdeadbeefcafebabe), 0);
    });

    test('one bit flipped → 1', () {
      expect(PhotosDedup.hammingDistance64(0, 1), 1);
      expect(PhotosDedup.hammingDistance64(0, 0x8000000000000000), 1);
    });

    test('all 64 bits flipped → 64', () {
      expect(PhotosDedup.hammingDistance64(0, -1), 64);
    });

    test('counts scattered bit differences correctly', () {
      expect(PhotosDedup.hammingDistance64(0x0, 0x1), 1);
      expect(PhotosDedup.hammingDistance64(0x0, 0x3), 2);
      expect(PhotosDedup.hammingDistance64(0x0, 0x7), 3);
      expect(PhotosDedup.hammingDistance64(0xaa, 0x55), 8);
    });
  });

  group('PhotosDedup.diff', () {
    test('sha256 match silently dedups regardless of pHash', () {
      final source = [_img(uri: 's/0', sha256Hex: 'aaa', pHash: 0)];
      final target = [_img(uri: 't/0', sha256Hex: 'AAA', pHash: 0xffffffff)];
      final report = PhotosDedup.diff(source: source, target: target);
      expect(report.exactDuplicates, 1);
      expect(report.newCount, 0);
      expect(report.conflictCount, 0);
    });

    test('pHash within threshold (no sha256 match) → conflict', () {
      // Two pHashes differing by a single bit — clearly the same image
      // re-encoded.
      final source = [_img(uri: 's/0', sha256Hex: 'aaa', pHash: 0xdead)];
      final target = [_img(uri: 't/0', sha256Hex: 'bbb', pHash: 0xdeac)];
      final report = PhotosDedup.diff(source: source, target: target);
      expect(report.exactDuplicates, 0);
      expect(report.newCount, 0);
      expect(report.conflictCount, 1);
      expect(report.conflicts.single.hammingDistance, 1);
    });

    test('pHash above threshold → new record (not a conflict)', () {
      // 64 bits different → completely unrelated.
      final source = [_img(uri: 's/0', sha256Hex: 'aaa', pHash: 0)];
      final target = [_img(uri: 't/0', sha256Hex: 'bbb', pHash: -1)];
      final report = PhotosDedup.diff(source: source, target: target);
      expect(report.newCount, 1);
      expect(report.conflictCount, 0);
    });

    test('threshold is configurable', () {
      // 4 bits different — within default (8) but above tighter threshold.
      final source = [_img(uri: 's/0', sha256Hex: 'aaa', pHash: 0x0)];
      final target = [_img(uri: 't/0', sha256Hex: 'bbb', pHash: 0xf)];
      expect(
        PhotosDedup.diff(source: source, target: target).conflictCount,
        1,
      );
      expect(
        PhotosDedup.diff(source: source, target: target, phashThreshold: 3)
            .conflictCount,
        0,
      );
    });

    test('records without pHash skip the fuzzy pass', () {
      // Source has no pHash → cannot fuzzy-match.
      final source = [_img(uri: 's/0', sha256Hex: 'aaa')];
      // Target has identical-pHash but different sha256 — would have matched
      // if the source carried a pHash.
      final target = [_img(uri: 't/0', sha256Hex: 'bbb', pHash: 0)];
      final report = PhotosDedup.diff(source: source, target: target);
      expect(report.newCount, 1);
      expect(report.conflictCount, 0);
    });

    test('best (lowest-distance) candidate wins', () {
      final source = [_img(uri: 's/0', sha256Hex: 'aaa', pHash: 0)];
      final target = [
        // Distance 4
        _img(uri: 't/0', sha256Hex: 'bbb', pHash: 0xf),
        // Distance 1 — should win
        _img(uri: 't/1', sha256Hex: 'ccc', pHash: 0x1),
      ];
      final report = PhotosDedup.diff(source: source, target: target);
      expect(report.conflictCount, 1);
      expect(report.conflicts.single.candidate.uri, 't/1');
      expect(report.conflicts.single.hammingDistance, 1);
    });

    test('source-side sha256 duplicates collapse to one transfer attempt', () {
      final source = [
        _img(uri: 's/0', sha256Hex: 'aaa'),
        _img(uri: 's/0-copy', sha256Hex: 'aaa'),
        _img(uri: 's/0-copy2', sha256Hex: 'aaa'),
      ];
      final report = PhotosDedup.diff(source: source, target: const []);
      expect(report.newCount, 1);
      expect(report.exactDuplicates, 0,
          reason: 'source-side dupes are dedup-collapsed, not target-matched');
    });

    test('sha256 comparison is case-insensitive', () {
      final source = [_img(uri: 's/0', sha256Hex: 'ABCdef')];
      final target = [_img(uri: 't/0', sha256Hex: 'abcDEF')];
      final report = PhotosDedup.diff(source: source, target: target);
      expect(report.exactDuplicates, 1);
    });
  });
}
