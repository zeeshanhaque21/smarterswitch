import 'dart:async';
import 'dart:io';

/// Per-category write-ahead log for resumable transfers.
///
/// On the receiver, after every successfully-written record we append the
/// record's monotonic sequence number to a category-scoped WAL file. If the
/// transport drops mid-transfer, on reconnect the receiver reads its
/// highest-acked sequence number from disk and sends a `Resume{lastAcked}`
/// frame. The sender skips ahead, and we resume without losing or
/// double-writing data.
///
/// On-disk format: each line is one decimal-encoded `uint64` sequence
/// number followed by a newline. Append-only. Line-buffered. The newest
/// (largest) value is the watermark.
///
/// Writing as text (rather than packed binary) is a deliberate choice:
/// makes manual debugging trivial (`tail -1 sms.wal`), and the per-record
/// overhead is ~10 bytes which is negligible compared to the records
/// themselves. Recovery is robust to a partial trailing line (the recovery
/// path skips any line that fails to parse).
class CategoryWal {
  CategoryWal._({
    required this.path,
    required IOSink sink,
    required int watermark,
  })  : _sink = sink,
        _watermark = watermark;

  final String path;
  IOSink _sink;
  int _watermark;

  /// Highest sequence number successfully written by either this session or
  /// a previous one. The next received frame must have `seq == watermark + 1`.
  int get watermark => _watermark;

  /// Open or create the WAL file at [path]. The directory must exist.
  /// Recovers the watermark by parsing the file (if present); otherwise
  /// starts at 0.
  static Future<CategoryWal> open(String path) async {
    final file = File(path);
    var watermark = 0;
    if (await file.exists()) {
      try {
        final contents = await file.readAsString();
        for (final line in contents.split('\n')) {
          final v = int.tryParse(line.trim());
          if (v != null && v > watermark) watermark = v;
        }
      } on FileSystemException {
        // Fresh start if the file is unreadable.
        watermark = 0;
      }
    }
    final sink = file.openWrite(mode: FileMode.writeOnlyAppend);
    return CategoryWal._(path: path, sink: sink, watermark: watermark);
  }

  /// Record that [seq] has been successfully written. Caller is responsible
  /// for ensuring monotonicity — out-of-order acks throw.
  Future<void> ack(int seq) async {
    if (seq <= _watermark) {
      throw StateError('WAL ack regression: got $seq, watermark is $_watermark');
    }
    _sink.writeln(seq);
    await _sink.flush();
    _watermark = seq;
  }

  /// Reset the WAL — delete all entries. Used at the end of a successful
  /// transfer to clean up; called from the Done screen.
  Future<void> reset() async {
    await _sink.close();
    final file = File(path);
    if (await file.exists()) await file.delete();
    _sink = file.openWrite(mode: FileMode.writeOnlyAppend);
    _watermark = 0;
  }

  Future<void> close() async {
    await _sink.flush();
    await _sink.close();
  }
}
