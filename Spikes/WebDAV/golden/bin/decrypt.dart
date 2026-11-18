// Decrypts sync files on disk with the app's rules and prints the JSON.
//
//   dart run bin/decrypt.dart <root> [--expect <expected.json>]
//
// <root> is a directory that contains `fehviewer/` (for example the local
// test server's data directory) or a single file below such a directory.
// Each file is decoded according to the directory it sits in and printed as
// one JSON object per line. With --expect the decoded records are compared
// with the expected file and the exit code is 1 on any difference.
import 'dart:convert';
import 'dart:io';

import 'package:eros_webdav_golden/check.dart';

void main(List<String> args) {
  final expectIndex = args.indexOf('--expect');
  final expectPath = expectIndex >= 0 ? args[expectIndex + 1] : null;
  final positional = [
    for (var i = 0; i < args.length; i++)
      if (i != expectIndex && i != expectIndex + 1) args[i]
  ];
  if (positional.length != 1 || (expectIndex >= 0 && expectPath == null)) {
    stderr.writeln('usage: dart run bin/decrypt.dart <root> [--expect file]');
    exit(64);
  }

  final input = positional.single;
  final files = FileSystemEntity.isDirectorySync(input)
      ? Directory(input)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => !f.path.split('/').last.startsWith('.'))
          .toList()
      : [File(input)];
  files.sort((a, b) => a.path.compareTo(b.path));

  final records = <Map<String, Object?>>[];
  for (final file in files) {
    final index = file.path.indexOf('/fehviewer/');
    if (index < 0) continue;
    final remotePath = file.path.substring(index);
    try {
      records.add(decodeRecord(remotePath, file.readAsBytesSync()));
    } catch (e) {
      records.add({'remotePath': remotePath, 'error': '$e'});
    }
  }
  for (final record in records) {
    stdout.writeln(jsonEncode(record));
  }

  final failed = records.where((r) => r.containsKey('error')).length;
  stdout.writeln('decoded ${records.length - failed}/${records.length} files');
  var exitCode = failed == 0 ? 0 : 1;
  if (expectPath != null) {
    final problems = compareWithExpected(records,
        jsonDecode(File(expectPath).readAsStringSync()) as Map<String, dynamic>);
    for (final p in problems) {
      stdout.writeln('MISMATCH $p');
    }
    stdout.writeln(problems.isEmpty
        ? 'expected: all ${records.length} files match $expectPath'
        : 'expected: ${problems.length} problem(s)');
    if (problems.isNotEmpty) exitCode = 1;
  }
  exit(exitCode);
}
