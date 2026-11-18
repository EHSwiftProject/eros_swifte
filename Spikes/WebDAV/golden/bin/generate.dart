// Generates the golden data for Spikes/WebDAV with the real encrypt 5.0.3
// and webdav_client 1.2.2 code paths.
//
//   dart run bin/generate.dart <output dir>
//
// Output (all content is fabricated; see lib/legacy.dart):
//   cipher-vectors.json   encryptAES/decrypt64 vectors and decrypt edge cases
//   url-vectors.json      request URLs webdav_client + dio build for paths
//   sample-tree/          a /fehviewer tree laid out by the app's rules
//   sample-tree-manifest.json  what the app parses out of every sample file
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:eros_webdav_golden/legacy.dart';
// ignore: implementation_imports
import 'package:webdav_client/src/utils.dart' as wd;

const _pretty = JsonEncoder.withIndent('  ');

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart run bin/generate.dart <output dir>');
    exit(64);
  }
  final out = Directory(args.single)..createSync(recursive: true);
  _writeJson(File('${out.path}/cipher-vectors.json'), _cipherVectors());
  _writeJson(File('${out.path}/url-vectors.json'), _urlVectors());
  final tree = Directory('${out.path}/sample-tree');
  if (tree.existsSync()) tree.deleteSync(recursive: true);
  _writeJson(
      File('${out.path}/sample-tree-manifest.json'), _sampleTree(tree.path));
  stdout.writeln('golden written to ${out.path}');
}

void _writeJson(File file, Object json) =>
    file.writeAsStringSync('${_pretty.convert(json)}\n');

String _describe(Object e) => '${e.runtimeType}: $e'.split('\n').first;

// ---------------------------------------------------------------------------

Map<String, Object?> _cipherVectors() {
  final plaintexts = <String, String>{
    'empty': '',
    'ascii': 'Hello, WebDAV!',
    'ascii-utf8-15': 'abcdefghijklmno',
    'ascii-utf8-16': 'abcdefghijklmnop',
    'ascii-utf8-17': 'abcdefghijklmnopq',
    'cjk-utf8-15': '你好世界abc',
    'cjk-utf8-16': '你好世界abcd',
    'cjk-utf8-17': '你好世界abcde',
    'ascii-utf8-31': 'abcdefghijklmnopqrstuvwxyz01234',
    'ascii-utf8-32': 'abcdefghijklmnopqrstuvwxyz012345',
    'ascii-utf8-33': 'abcdefghijklmnopqrstuvwxyz0123456',
    'cjk-kana-emoji': '中文 日本語のテスト 🍣🔍 👨‍👩‍👧 完了',
    'json-escapes': '{"a":"quote \\" backslash \\\\ tab \\t newline \\n"}\n\ttail',
    // 6000 bytes: more than 207 blocks, so the counter's last byte (0x30)
    // wraps and carries into the next byte.
    'long-counter-carry':
        List.generate(375, (i) => (i % 16).toRadixString(16) * 16).join(),
    'history-json': jsonEncode(fakeHistory(
      gid: '1000001',
      token: '0000000001',
      lastViewTime: 1762000000000,
      englishTitle: '[Fake Circle] Sample Gallery Vol.1',
      japaneseTitle: '[示例社团] サンプル画廊 第1巻',
      rating: 4.5,
    )),
    'read-json': jsonEncode(fakeReadProgress(
        gid: '1000001', lastIndex: 12, lastOffset: null, time: 1762000050000)),
  };

  final vectors = <Map<String, Object?>>[];
  for (final entry in plaintexts.entries) {
    final plaintext = entry.value;
    final utf8Length = utf8.encode(plaintext).length;
    final v = <String, Object?>{
      'name': entry.key,
      'plaintext': plaintext,
      'utf8Length': utf8Length,
    };
    try {
      final c1 = legacyEncrypt(plaintext);
      final c2 = legacyEncrypt(plaintext);
      v['ciphertextBase64'] = c1;
      v['ciphertextLength'] = base64.decode(c1).length;
      v['deterministic'] = c1 == c2;
      v['decryptsBack'] = legacyEncrypter.decrypt64(c1, iv: legacyIV) == plaintext;
    } catch (e) {
      // AES(key) defaults to AES/SIC/PKCS7; PaddedBlockCipherImpl.process
      // indexes block -1 for empty input and throws.
      v['encryptError'] = _describe(e);
      // The ciphertext a correct PKCS7 implementation would produce (one
      // block of 0x10) and whether the app can decrypt it.
      final sic = encrypt.Encrypter(
          encrypt.AES(legacyKey, mode: encrypt.AESMode.sic, padding: null));
      final padded = sic
          .encryptBytes(Uint8List.fromList(List.filled(16, 16)), iv: legacyIV)
          .base64;
      v['paddedBlockCiphertextBase64'] = padded;
      v['paddedBlockDecryptsTo'] =
          legacyEncrypter.decrypt64(padded, iv: legacyIV);
    }
    vectors.add(v);
  }

  // How decrypt64 reacts to inputs a server or a user could produce.
  final good = legacyEncrypt('Hello, WebDAV!');
  final goodBytes = base64.decode(good);
  final tampered = Uint8List.fromList(goodBytes)..[15] ^= 0x01;
  // First plaintext whose ciphertext needs both '+' and '/' in Base64.
  var urlSafeSource = '';
  for (var i = 0;; i++) {
    final b64 = legacyEncrypt('$i alphabet probe');
    if (b64.contains('+') && b64.contains('/')) {
      urlSafeSource = b64;
      break;
    }
  }
  // Same 16 bytes, but the last Base64 digit before '==' has non-zero
  // trailing bits, which a canonical encoder never emits.
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final lastDigit = alphabet.indexOf(good[good.length - 3]);
  final nonCanonical = good.substring(0, good.length - 3) +
      alphabet[lastDigit | 0x01] +
      good.substring(good.length - 2);
  final decryptCases = <String, String>{
    'valid': good,
    'non-canonical-trailing-bits': nonCanonical,
    'percent-encoded-padding': good.replaceAll('=', '%3D'),
    'missing-base64-padding': good.replaceAll('=', ''),
    'trailing-newline': '$good\n',
    'surrounding-spaces': ' $good ',
    'standard-alphabet-with-plus-and-slash': urlSafeSource,
    'url-safe-alphabet':
        urlSafeSource.replaceAll('+', '-').replaceAll('/', '_'),
    'not-base64': 'this is not base64!',
    'empty-input': '',
    'length-not-multiple-of-16': base64.encode(goodBytes.sublist(0, 15)),
    'corrupted-padding': base64.encode(tampered),
  };
  final cases = <Map<String, Object?>>[];
  for (final entry in decryptCases.entries) {
    final c = <String, Object?>{'name': entry.key, 'input': entry.value};
    try {
      c['plaintext'] = legacyEncrypter.decrypt64(entry.value, iv: legacyIV);
      c['accepted'] = true;
    } catch (e) {
      c['accepted'] = false;
      c['error'] = _describe(e);
    }
    cases.add(c);
  }

  return {
    'generator': 'Spikes/WebDAV/golden/bin/generate.dart',
    'dart': Platform.version.split(' ').first,
    'packages': {'encrypt': '5.0.3', 'pointycastle': '3.9.1'},
    'construction':
        "Encrypter(AES(Key.fromUtf8(kAESKey))).encrypt(text, iv: IV.fromUtf8(kAESIV)).base64",
    'algorithm': 'AES/SIC/PKCS7 (AES() default mode is SIC, i.e. CTR)',
    'key': kAESKey,
    'iv': kAESIV,
    'vectors': vectors,
    'decryptCases': cases,
  };
}

// ---------------------------------------------------------------------------

Map<String, Object?> _urlVectors() {
  const base = 'http://127.0.0.1:18080/dav/';
  final client = wd.fixSlash(base); // newClient, client.dart:223
  final paths = <String>[
    '${wd.fixSlashes(kHistoryDtlDirPath)}', // readDir/mkdirAll add both slashes
    historyPath('1000001', 1762000000000),
    historyDeletePath('1000003'),
    readPath('1000001'),
    groupPath('汉语', '00000000-0000-4000-8000-000000000001', 1762000200000),
    groupPath('Fake Artist [Test] & 同人+', '00000000-0000-4000-8000-000000000002', 1762000210000),
    groupPath('100% fake', '00000000-0000-4000-8000-000000000003', 1),
    groupPath('C#', '00000000-0000-4000-8000-000000000004', 1),
    groupPath('why?', '00000000-0000-4000-8000-000000000005', 1),
    groupPath('サンプル ｶﾅ', '00000000-0000-4000-8000-000000000006', 1),
    // A valid %XX stays an escape and escaped unreserved characters are
    // decoded ('a%41b' is sent as 'aAb'); a backslash becomes a slash.
    groupPath('a%41b', '00000000-0000-4000-8000-000000000007', 1),
    groupPath('x%e5%90%8Cy', '00000000-0000-4000-8000-000000000008', 1),
    groupPath('a\\b', '00000000-0000-4000-8000-000000000009', 1),
    quickSearchPath(1762000300000),
  ];
  final vectors = <Map<String, Object?>>[];
  for (final path in paths) {
    final v = <String, Object?>{'remotePath': path};
    try {
      // webdav_dio.dart:81-83, then dio: requestUri -> uri.toString() ->
      // RequestOptions.uri = Uri.parse(url).normalizePath() (options.dart:607-621).
      final first = Uri.parse(wd.join(client, path));
      final uri = Uri.parse(first.toString()).normalizePath();
      v['url'] = uri.toString();
      v['requestTarget'] = uri.path + (uri.hasQuery ? '?${uri.query}' : '');
      v['fragmentDropped'] = uri.hasFragment;
      v['decodedPath'] = Uri.decodeFull(uri.path);
    } catch (e) {
      v['error'] = _describe(e);
    }
    vectors.add(v);
  }
  return {
    'generator': 'Spikes/WebDAV/golden/bin/generate.dart',
    'packages': {'webdav_client': '1.2.2', 'dio': '5.9.0'},
    'baseURL': base,
    'vectors': vectors,
  };
}

// ---------------------------------------------------------------------------

Map<String, Object?> _sampleTree(String root) {
  final files = <Map<String, Object?>>[];

  void put(String remotePath, String content, Map<String, Object?> meta) {
    final file = File('$root$remotePath');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    files.add({'remotePath': remotePath, 'size': utf8.encode(content).length, ...meta});
  }

  // History details: AES of jsonEncode(GalleryProvider).
  for (final h in [
    fakeHistory(
      gid: '1000001',
      token: '0000000001',
      lastViewTime: 1762000000000,
      englishTitle: '[Fake Circle] Sample Gallery Vol.1',
      japaneseTitle: '[示例社团] サンプル画廊 第1巻',
      rating: 4.5,
    ),
    fakeHistory(
      gid: '1000002',
      token: '0000000002',
      lastViewTime: 1762000100000,
      englishTitle: 'Fake Anthology 🍣 Edition',
      japaneseTitle: 'フェイク合同誌 🍣',
      rating: 4.0, // Dart writes "4.0"
    ),
  ]) {
    final json = jsonEncode(h);
    put(historyPath(h['gid'] as String, h['lastViewTime'] as int),
        legacyEncrypt(json), {
      'kind': 'history',
      'encrypted': true,
      'parsedName': legacyParseHistoryNames(
          ['${h['gid']}_${h['lastViewTime']}.json']).single,
      'json': jsonDecode(json),
    });
  }

  // Before 690502e2 (2021-08-30) the app uploaded plain JSON; the
  // startsWith('{') branch added in that commit still reads these files.
  final preAes = fakePreAesGalleryItem(
      gid: '1000004', token: '0000000004', lastViewTime: 1629000000000);
  final preAesJson = jsonEncode(preAes);
  put(historyPath('1000004', 1629000000000), preAesJson, {
    'kind': 'history',
    'encrypted': false,
    'note': 'pre-AES GalleryItem shape, plain JSON (before 690502e2)',
    'parsedName':
        legacyParseHistoryNames(['1000004_1629000000000.json']).single,
    'json': jsonDecode(preAesJson),
  });

  // History deletion flag: empty file named by gid (updateRemoveFlg).
  put(historyDeletePath('1000003'), '', {
    'kind': 'historyDeletion',
    'parsedName': legacyParseDeleteNames(['1000003']).single,
  });

  // Read progress: AES of jsonEncode(GalleryCache).
  for (final r in [
    fakeReadProgress(
        gid: '1000001', lastIndex: 12, lastOffset: null, time: 1762000050000),
    fakeReadProgress(
        gid: '1000002', lastIndex: 0, lastOffset: 1536.5, time: 1762000150000),
  ]) {
    final json = jsonEncode(r);
    put(readPath(r['gid'] as String), legacyEncrypt(json), {
      'kind': 'readProgress',
      'encrypted': true,
      'parsedName': legacyParseReadNames(['${r['gid']}.json']).single,
      'json': jsonDecode(json),
    });
  }
  // Pre-AES read progress: plain JSON, same GalleryCache keys
  // (690502e2^:lib/common/controller/webdav_controller.dart:299-304).
  final preAesRead = jsonEncode(fakeReadProgress(
      gid: '1000004', lastIndex: 5, lastOffset: null, time: 1629000050000));
  put(readPath('1000004'), preAesRead, {
    'kind': 'readProgress',
    'encrypted': false,
    'note': 'pre-AES plain JSON (before 690502e2)',
    'parsedName': legacyParseReadNames(['1000004.json']).single,
    'json': jsonDecode(preAesRead),
  });

  // Groups: uploadGroupProfile defaults to isEncrypt = false, so the app
  // writes plain JSON; downloadGroupProfile also accepts AES. One of each.
  final groups = [
    (
      fakeGroup(
          uuid: '00000000-0000-4000-8000-000000000001',
          name: '汉语',
          searchText: ['l:chinese'],
          lastEditTime: 1762000200000),
      false
    ),
    (
      fakeGroup(
          uuid: '00000000-0000-4000-8000-000000000002',
          name: 'Fake Artist [Test] & 同人+',
          searchText: ['artist:"fake artist\$"', 'other:"fake tag\$"'],
          lastEditTime: 1762000210000,
          withAdvanceSearch: true),
      true
    ),
  ];
  for (final (g, encrypted) in groups) {
    final json = jsonEncode(g);
    final name = g['name'] as String;
    final uuid = g['uuid'] as String;
    final time = g['lastEditTime'] as int;
    put(groupPath(name, uuid, time), encrypted ? legacyEncrypt(json) : json, {
      'kind': 'group',
      'encrypted': encrypted,
      'parsedName': legacyParseGroupNames(
          ['${legacyGroupSyncFileName(name, uuid, time)}.json']).single,
      'json': jsonDecode(json),
    });
  }

  // Quick search: plain text, one entry per line (uploadQuickSearch).
  final lines = ['l:chinese\$', 'other:"fake tag\$"', '示例 検索 🔍', '  '];
  put(quickSearchPath(1762000300000), lines.join('\n'), {
    'kind': 'quickSearch',
    'encrypted': false,
    'parsedName':
        legacyParseQuickSearchNames(['${kQuickSearchFile}_1762000300000.txt'])
            .single,
    'lines': legacyDecodeQuickSearch(lines.join('\n')),
  });

  // Every directory the app creates at startup (initClient -> checkDir).
  for (final dir in [
    kHistoryDtlDirPath,
    kHistoryDelDirPath,
    kReadDirPath,
    kGroupDirPath,
    kSearchDirPath
  ]) {
    Directory('$root$dir').createSync(recursive: true);
  }

  return {
    'generator': 'Spikes/WebDAV/golden/bin/generate.dart',
    'note': 'All values are fabricated; gid 1000001+ and zero UUIDs are placeholders.',
    'files': files,
  };
}
