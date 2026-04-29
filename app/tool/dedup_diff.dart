// Multi-category dedup validation harness — Phase 1+ tooling.
//
//   dart run tool/dedup_diff.dart --category=calllog \
//     --source A.json --target B.json [--json]
//   dart run tool/dedup_diff.dart --category=calendar -s A.json -t B.json
//   dart run tool/dedup_diff.dart --category=contacts -s A.json -t B.json
//   dart run tool/dedup_diff.dart --category=photos   -s A.json -t B.json
//
// JSON input shape per record matches the corresponding model class — see
// `app/lib/core/io/category_json.dart` for the exact field names.
//
// SMS uses a separate harness (`tool/sms_diff.dart`) because SMS Backup &
// Restore's XML format is the de-facto export source for that category and
// we get it for free; the rest don't have an established export tool, so
// JSON is the easiest path.

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:smarterswitch/core/dedup/calendar_dedup.dart';
import 'package:smarterswitch/core/dedup/call_log_dedup.dart';
import 'package:smarterswitch/core/dedup/contacts_dedup.dart';
import 'package:smarterswitch/core/dedup/photos_dedup.dart';
import 'package:smarterswitch/core/io/category_json.dart';

Future<int> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('category',
        abbr: 'c',
        help: 'One of: calllog, calendar, contacts, photos.')
    ..addOption('source', abbr: 's', help: 'Source JSON export.')
    ..addOption('target', abbr: 't', help: 'Target JSON export.')
    ..addFlag('json', help: 'Emit JSON output.')
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(parser.usage);
    return 2;
  }

  if (args['help'] as bool ||
      args['source'] == null ||
      args['target'] == null ||
      args['category'] == null) {
    stdout.writeln('dedup_diff — multi-category dedup validation harness\n');
    stdout.writeln(parser.usage);
    return args['help'] as bool ? 0 : 2;
  }

  final source = File(args['source'] as String);
  final target = File(args['target'] as String);
  final asJson = args['json'] as bool;
  final category = args['category'] as String;

  Map<String, Object?> report;
  try {
    report = _runDiff(category, source, target);
  } on FormatException catch (e) {
    stderr.writeln('Parse error: ${e.message}');
    return 1;
  } on FileSystemException catch (e) {
    stderr.writeln('File error: ${e.message}');
    return 1;
  }

  if (asJson) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
  } else {
    for (final e in report.entries) {
      stdout.writeln('${e.key}: ${e.value}');
    }
  }
  return 0;
}

Map<String, Object?> _runDiff(String category, File source, File target) {
  switch (category) {
    case 'calllog':
      final r = CallLogDedup.diff(
        source: CategoryJson.readCallLog(source),
        target: CategoryJson.readCallLog(target),
      );
      return {
        'source_total': r.sourceTotal,
        'target_total': r.targetTotal,
        'duplicates_skipped': r.duplicatesSkipped,
        'new_records': r.newCount,
      };
    case 'calendar':
      final r = CalendarDedup.diff(
        source: CategoryJson.readCalendar(source),
        target: CategoryJson.readCalendar(target),
      );
      return {
        'source_total': r.sourceTotal,
        'target_total': r.targetTotal,
        'duplicates_skipped': r.duplicatesSkipped,
        'new_records': r.newCount,
      };
    case 'contacts':
      final r = ContactsDedup.diff(
        source: CategoryJson.readContacts(source),
        target: CategoryJson.readContacts(target),
      );
      return {
        'source_total': r.sourceTotal,
        'target_total': r.targetTotal,
        'exact_duplicates': r.exactDuplicates,
        'fuzzy_conflicts': r.conflictCount,
        'delegated_to_cloud': r.delegatedToCloud.length,
        'new_records': r.newCount,
      };
    case 'photos':
      final r = PhotosDedup.diff(
        source: CategoryJson.readMedia(source),
        target: CategoryJson.readMedia(target),
      );
      return {
        'source_total': r.sourceTotal,
        'target_total': r.targetTotal,
        'exact_duplicates': r.exactDuplicates,
        'fuzzy_conflicts': r.conflictCount,
        'new_records': r.newCount,
      };
    default:
      throw FormatException('Unknown category: $category');
  }
}
