// CLI harness for the SMS dedup engine — Phase 1 validation tool.
//
// Run with:
//   dart run tool/sms_diff.dart --source export-from-A.xml --target export-from-B.xml
//
// Optional flags:
//   --misses path/to/dump.txt   Write the records that would be transferred
//                               (one per line: timestamp \t address \t body)
//   --json                      Emit the report as JSON instead of human text.
//
// Exits 0 if the files parsed and the diff completed; 2 on usage error; 1 on
// any parse/IO failure.

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:smarterswitch/core/dedup/sms_dedup.dart';
import 'package:smarterswitch/core/io/sms_backup_xml.dart';
import 'package:smarterswitch/core/model/sms_record.dart';

Future<int> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('source', abbr: 's', help: 'XML export from the source phone.')
    ..addOption('target', abbr: 't', help: 'XML export from the target phone.')
    ..addOption('misses',
        help: 'If set, dump records that would be transferred to this path.')
    ..addFlag('json', defaultsTo: false, help: 'Emit JSON.')
    ..addFlag('help', abbr: 'h', defaultsTo: false, negatable: false);

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(parser.usage);
    return 2;
  }

  if (args['help'] as bool || args['source'] == null || args['target'] == null) {
    stdout.writeln('sms_diff — SMS dedup validation harness\n');
    stdout.writeln(parser.usage);
    return args['help'] as bool ? 0 : 2;
  }

  final sourcePath = args['source'] as String;
  final targetPath = args['target'] as String;

  final List<SmsRecord> source;
  final List<SmsRecord> target;
  try {
    source = SmsBackupXml.parse(await File(sourcePath).readAsString());
    target = SmsBackupXml.parse(await File(targetPath).readAsString());
  } catch (e) {
    stderr.writeln('Failed to read or parse XML: $e');
    return 1;
  }

  final report = SmsDedup.diff(source: source, target: target);

  if (args['json'] as bool) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert({
      'source_total': report.sourceTotal,
      'target_total': report.targetTotal,
      'duplicates_skipped': report.duplicatesSkipped,
      'new_records': report.newCount,
    }));
  } else {
    stdout.writeln('Source ($sourcePath): ${report.sourceTotal} records');
    stdout.writeln('Target ($targetPath): ${report.targetTotal} records');
    stdout.writeln('Duplicates (would skip): ${report.duplicatesSkipped}');
    stdout.writeln('New (would transfer):    ${report.newCount}');
  }

  final missesPath = args['misses'] as String?;
  if (missesPath != null) {
    final f = File(missesPath);
    final sink = f.openWrite();
    for (final r in report.newRecords) {
      sink.writeln('${r.timestampMs}\t${r.address}\t${r.body.replaceAll('\n', ' ')}');
    }
    await sink.flush();
    await sink.close();
    stderr.writeln('Wrote ${report.newCount} miss records to ${f.path}');
  }

  return 0;
}
