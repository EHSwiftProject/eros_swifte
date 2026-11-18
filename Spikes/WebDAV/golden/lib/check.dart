// Decoding and comparison shared by bin/decrypt.dart and bin/legacy_client.dart.
//
// The expected-file format is the one sample-tree-manifest.json uses and the
// Swift integration test writes: {"files": [{"remotePath", "kind", "json" |
// "lines"}]}.
import 'dart:convert';

import 'package:collection/collection.dart';

import 'legacy.dart';

/// Record kind by remote directory, using the app's directory constants.
String? kindOf(String remotePath) {
  final dir = remotePath.substring(0, remotePath.lastIndexOf('/'));
  return switch (dir) {
    kHistoryDtlDirPath => 'history',
    kHistoryDelDirPath => 'historyDeletion',
    kReadDirPath => 'readProgress',
    kGroupDirPath => 'group',
    kSearchDirPath => 'quickSearch',
    _ => null,
  };
}

/// Decodes a downloaded file the way the app does and runs the matching
/// model round trip, so a parse failure in the app shows up here too.
Map<String, Object?> decodeRecord(String remotePath, List<int> bytes) {
  final kind = kindOf(remotePath);
  final text = utf8.decode(bytes);
  final record = <String, Object?>{'remotePath': remotePath, 'kind': kind};
  switch (kind) {
    case 'history':
      final json = jsonDecode(legacyDecodePayload(text)) as Map<String, dynamic>;
      legacyGalleryProviderRoundTrip(json);
      record['json'] = json;
    case 'readProgress':
      final json = jsonDecode(legacyDecodePayload(text)) as Map<String, dynamic>;
      legacyGalleryCacheRoundTrip(json);
      record['json'] = json;
    case 'group':
      final json = jsonDecode(legacyDecodePayload(text)) as Map<String, dynamic>;
      legacyCustomProfileRoundTrip(json);
      record['json'] = json;
    case 'quickSearch':
      record['lines'] = legacyDecodeQuickSearch(text);
    case 'historyDeletion':
      record['size'] = bytes.length;
    default:
      record['error'] = 'not a sync file';
  }
  return record;
}

const _deep = DeepCollectionEquality();

/// Compares decoded records with an expected file. Returns problems; an empty
/// list means every expected file was found with equal content and nothing
/// unexpected was present.
List<String> compareWithExpected(
    List<Map<String, Object?>> actual, Map<String, dynamic> expectedDoc) {
  final problems = <String>[];
  final expected = {
    for (final f in (expectedDoc['files'] as List).cast<Map<String, dynamic>>())
      f['remotePath'] as String: f
  };
  final seen = <String>{};
  for (final record in actual) {
    final path = record['remotePath'] as String;
    final want = expected[path];
    if (want == null) {
      problems.add('unexpected file $path');
      continue;
    }
    seen.add(path);
    if (record['kind'] != want['kind']) {
      problems.add('$path: kind ${record['kind']} != ${want['kind']}');
    }
    for (final key in ['json', 'lines']) {
      if (want.containsKey(key) && !_deep.equals(record[key], want[key])) {
        problems.add('$path: $key differs');
      }
    }
  }
  for (final path in expected.keys.where((p) => !seen.contains(p))) {
    problems.add('missing file $path');
  }
  return problems;
}
