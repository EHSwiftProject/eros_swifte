// Plays the Flutter app's side of WebDAV sync against a server, using
// webdav_client 1.2.2 the way lib/common/controller/webdav_controller.dart
// does (same client setup, same request sequence, same name parsing).
//
//   dart run bin/legacy_client.dart <mode> --url <base> --user <u> --password <p> [options]
//
// Modes:
//   write --manifest <sample-tree-manifest.json>
//       Uploads every record of the manifest with the app's upload calls.
//   sync-demo
//       Replays the app's update/delete pattern (new history version plus
//       delete of the old one, quick search replace, group replace, deleting
//       a missing file) so the server log shows the legacy requests.
//   names-demo
//       Uploads groups whose names the legacy request path rewrites
//       (url-vectors.json: '\\' and a valid %XX) and shows what the app's
//       own listing makes of the result.
//   read [--expect <expected.json>]
//       Lists and downloads like the app's sync code, decodes every file and,
//       with --expect, compares the result (exit 1 on any difference).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:eros_webdav_golden/check.dart';
import 'package:eros_webdav_golden/legacy.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

late final Directory _temp;

Future<void> main(List<String> args) async {
  if (args.isEmpty) _usage();
  final mode = args.first;
  final options = <String, String>{};
  for (var i = 1; i + 1 < args.length; i += 2) {
    if (!args[i].startsWith('--')) _usage();
    options[args[i].substring(2)] = args[i + 1];
  }
  final url = options['url'] ?? _usage();
  _temp = Directory.systemTemp.createTempSync('eros-legacy-client-');
  try {
    if (mode != 'read') {
      await _ensureBase(url, options['user'] ?? '', options['password'] ?? '');
    }
    final client = await _initClient(
        url, options['user'] ?? '', options['password'] ?? '');
    switch (mode) {
      case 'write':
        await _write(client, options['manifest'] ?? _usage());
      case 'sync-demo':
        await _syncDemo(client);
      case 'names-demo':
        await _namesDemo(client);
      case 'read':
        exitCode = await _read(client, options['expect']);
      default:
        _usage();
    }
  } finally {
    _temp.deleteSync(recursive: true);
  }
}

Never _usage() {
  stderr.writeln('usage: dart run bin/legacy_client.dart write|sync-demo|names-demo|read '
      '--url <base> --user <u> --password <p> [--manifest f] [--expect f]');
  exit(64);
}

/// A user's base URL always exists; the spike's per-test sub-bases may not.
Future<void> _ensureBase(String url, String user, String pwd) async {
  final uri = Uri.parse(url);
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  final parent = uri.replace(
      path: '/${segments.take(segments.length - 1).map((s) => '$s/').join()}');
  await webdav
      .newClient(parent.toString(), user: user, password: pwd)
      .mkdir(segments.last);
}

/// webdav_controller.dart:177-207 (initClient) and 209-219 (checkDir).
Future<webdav.Client> _initClient(String url, String user, String pwd) async {
  final client = webdav.newClient(url, user: user, password: pwd);
  client.setHeaders({'accept-charset': 'utf-8'});
  client.setConnectTimeout(8000);
  client.setSendTimeout(8000);
  client.setReceiveTimeout(8000);
  for (final dir in [
    kHistoryDtlDirPath,
    kHistoryDelDirPath,
    kReadDirPath,
    kGroupDirPath,
    kSearchDirPath
  ]) {
    try {
      await client.readDir(dir);
    } on DioException catch (err) {
      if (err.response?.statusCode == 404) {
        await client.mkdirAll(dir);
      }
    }
  }
  return client;
}

/// writeFromFile through a temp file, as every upload in the app does.
Future<void> _upload(webdav.Client client, String remotePath, String text) async {
  final file = File('${_temp.path}/${remotePath.hashCode}')
    ..writeAsStringSync(text);
  await client.writeFromFile(file.path, remotePath);
}

Future<void> _write(webdav.Client client, String manifestPath) async {
  final manifest =
      jsonDecode(File(manifestPath).readAsStringSync()) as Map<String, dynamic>;
  var count = 0;
  for (final f in (manifest['files'] as List).cast<Map<String, dynamic>>()) {
    final path = f['remotePath'] as String;
    switch (f['kind']) {
      case 'history' || 'readProgress' || 'group':
        final text = jsonEncode(f['json']);
        await _upload(
            client, path, f['encrypted'] == true ? legacyEncrypt(text) : text);
      case 'historyDeletion':
        // updateRemoveFlg, webdav_controller.dart:252-254.
        await client.write(path, Uint8List.fromList([]));
      case 'quickSearch':
        await _upload(client, path, (f['lines'] as List).join('\n'));
    }
    count++;
  }
  stdout.writeln('legacy client wrote $count files');
}

Future<void> _syncDemo(webdav.Client client) async {
  final v1 = fakeHistory(
      gid: '1000201',
      token: '0000000201',
      lastViewTime: 1762000400000,
      englishTitle: 'Fake Demo',
      japaneseTitle: 'デモ',
      rating: 3.5);
  await _upload(client, historyPath('1000201', 1762000400000),
      legacyEncrypt(jsonEncode(v1)));
  // _uploadHistoriesWebDAV (history_controller.dart:282-286): upload the new
  // version and delete the old file concurrently.
  final v2 = {...v1, 'lastViewTime': 1762000500000};
  await Future.wait([
    _upload(client, historyPath('1000201', 1762000500000),
        legacyEncrypt(jsonEncode(v2))),
    client.remove(historyPath('1000201', 1762000400000)),
  ]);
  // syncQuickSearch (quicksearch_controller.dart:50-55): upload, then delete
  // every older remote version.
  await _upload(client, quickSearchPath(1762000600000), 'demo 1');
  await _upload(client, quickSearchPath(1762000700000), 'demo 1\ndemo 2');
  await client.remove(
      '$kSearchDirPath/$kQuickSearchFile$kQuickSearchSeparator${1762000600000}.txt');
  // _uploadProfiles (custom_tabbar_controller.dart:407-415).
  const uuid = '00000000-0000-4000-8000-000000000201';
  final g1 = fakeGroup(
      uuid: uuid, name: 'Demo', searchText: ['demo'], lastEditTime: 1762000800000);
  await _upload(client, groupPath('Demo', uuid, 1762000800000), jsonEncode(g1));
  final g2 = {...g1, 'lastEditTime': 1762000900000};
  await Future.wait([
    _upload(client, groupPath('Demo', uuid, 1762000900000), jsonEncode(g2)),
    client.remove(groupPath('Demo', uuid, 1762000800000)),
  ]);
  // removeAll treats 404 as success (client.dart:128-136).
  await client.remove(historyPath('1000299', 1));
  for (final dir in [kHistoryDtlDirPath, kSearchDirPath, kGroupDirPath]) {
    final names = (await client.readDir(dir)).map((e) => e.name).toList();
    stdout.writeln('$dir -> $names');
  }
}

String _short(Object e) => e is DioException
    ? 'DioException status ${e.response?.statusCode}'
    : '${e.runtimeType}: ${e.toString().split('\n').first}';

Future<void> _namesDemo(webdav.Client client) async {
  const uuid = '00000000-0000-4000-8000-000000000401';
  for (final name in ['a\\b', 'a%41b']) {
    final group =
        fakeGroup(uuid: uuid, name: name, searchText: ['x'], lastEditTime: 1);
    try {
      await _upload(client, groupPath(name, uuid, 1), jsonEncode(group));
      stdout.writeln('upload ${jsonEncode(name)}: ok');
    } catch (e) {
      stdout.writeln('upload ${jsonEncode(name)}: ${_short(e)}');
    }
  }
  final names = await _names(client, kGroupDirPath);
  stdout.writeln('group listing: ${jsonEncode(names)}');
  try {
    stdout.writeln(
        'getRemoteGroupList: ${jsonEncode(legacyParseGroupNames(names))}');
  } catch (e) {
    stdout.writeln('getRemoteGroupList throws ${_short(e)}');
  }
}

Future<List<String?>> _names(webdav.Client client, String dir) async =>
    (await client.readDir(dir)).map((e) => e.name).toList();

Future<List<int>> _download(webdav.Client client, String remotePath) async {
  final local = '${_temp.path}/dl-${remotePath.hashCode}';
  await client.read2File(remotePath, local);
  return File(local).readAsBytesSync();
}

Future<int> _read(webdav.Client client, String? expectPath) async {
  final records = <Map<String, Object?>>[];
  Future<void> fetch(String remotePath) async {
    try {
      records.add(decodeRecord(remotePath, await _download(client, remotePath)));
    } catch (e) {
      records.add({'remotePath': remotePath, 'error': '$e'});
    }
  }

  // Same listing + reconstruction the app performs before each download.
  for (final h in legacyParseHistoryNames(await _names(client, kHistoryDtlDirPath))) {
    await fetch(historyPath(h['g'] as String, h['t'] as int));
  }
  for (final gid in legacyParseReadNames(await _names(client, kReadDirPath))) {
    await fetch(readPath(gid));
  }
  for (final g in legacyParseGroupNames(await _names(client, kGroupDirPath))) {
    await fetch(groupPath(
        g['name'] as String, g['uuid'] as String, g['lastEditTime'] as int));
  }
  final times = legacyParseQuickSearchNames(await _names(client, kSearchDirPath));
  if (times.isNotEmpty) {
    // downloadQuickSearch only fetches the newest version.
    await fetch(quickSearchPath(times.reduce((a, b) => a > b ? a : b)));
  }
  final delEntries = await client.readDir(kHistoryDelDirPath);
  for (final e in delEntries) {
    records.add({
      'remotePath': historyDeletePath(e.name!),
      'kind': 'historyDeletion',
      'size': e.size,
    });
  }

  for (final record in records) {
    stdout.writeln(jsonEncode(record));
  }
  final failed = records.where((r) => r.containsKey('error')).length;
  stdout.writeln('legacy client decoded ${records.length - failed}/${records.length} files');
  var code = failed == 0 ? 0 : 1;
  if (expectPath != null) {
    final problems = compareWithExpected(records,
        jsonDecode(File(expectPath).readAsStringSync()) as Map<String, dynamic>);
    for (final p in problems) {
      stdout.writeln('MISMATCH $p');
    }
    stdout.writeln(problems.isEmpty
        ? 'expected: all ${records.length} files match $expectPath'
        : 'expected: ${problems.length} problem(s)');
    if (problems.isNotEmpty) code = 1;
  }
  return code;
}
