// Mirrors of the Flutter app's WebDAV sync rules (eros_fe 1.9.3+567, frozen).
//
// Every constant and rule is copied from the file and line cited next to it,
// so that the golden data and the legacy-client simulator behave exactly like
// the app. Paths are relative to the frozen worktree
// iphone-duo-adaptation-handoff-b206c1.
import 'package:encrypt/encrypt.dart' as encrypt;

// lib/common/controller/webdav_controller.dart:16-36
const String kDirPath = '/fehviewer';
const String kHistoryDirPath = '/fehviewer/history';
const String kHistoryDtlDirPath = '/fehviewer/history/s';
const String kHistoryDelDirPath = '/fehviewer/history/del';
const String kReadDirPath = '/fehviewer/read';
const String kGroupDirPath = '/fehviewer/group';
const String kGroupSeparator = '‖@‖';
const String kSearchDirPath = '/fehviewer/search';
const String kQuickSearchFile = 'quickSearch';
const String kQuickSearchSeparator = '_';
const String kAESKey = 'fehviewer is very good!!';
const String kAESIV = '0000000000000000';

// lib/common/controller/webdav_controller.dart:163-165
final encrypt.Key legacyKey = encrypt.Key.fromUtf8(kAESKey);
final encrypt.IV legacyIV = encrypt.IV.fromUtf8(kAESIV);
final encrypt.Encrypter legacyEncrypter =
    encrypt.Encrypter(encrypt.AES(legacyKey));

/// webdav_controller.dart:293-295 (history), 367-368 (read), 440-441 (group).
String legacyEncrypt(String text) =>
    legacyEncrypter.encrypt(text, iv: legacyIV).base64;

/// webdav_controller.dart:326-331, 398-403, 477-482.
String legacyDecodePayload(String fileText) => fileText.startsWith('{')
    ? fileText
    : legacyEncrypter.decrypt64(fileText, iv: legacyIV);

/// webdav_controller.dart:570-577.
List<String> legacyDecodeQuickSearch(String fileText) =>
    fileText.split('\n').where((element) => element.trim().isNotEmpty).toList();

// ---------------------------------------------------------------------------
// File name rules. Each function takes the `name` values that
// webdav_client's readDir returns and applies the app's parsing verbatim
// (including its crashes: callers catch and report them).

/// webdav_controller.dart:256-271 (getRemoteHistoryList).
List<Map<String, Object?>> legacyParseHistoryNames(List<String?> names) {
  final hisObjs = names.map((n) {
    final name = n?.substring(0, n.lastIndexOf('.'));
    final gid = name?.split('_')[0];
    final time = int.parse(name?.split('_')[1] ?? '0');
    return <String, Object?>{'g': gid, 't': time};
  }).toList();
  return hisObjs
      .where((his) => his['g'] != null && (his['t'] as int) > 0)
      .toList();
}

/// webdav_controller.dart:240-250 (getRemotDeleteList; no live caller).
List<String> legacyParseDeleteNames(List<String?> names) =>
    names.whereType<String>().toList();

/// webdav_controller.dart:414-426 (getRemotReadList).
List<String> legacyParseReadNames(List<String?> names) => names
    .map((n) => n?.substring(0, n.lastIndexOf('.')))
    .whereType<String>()
    .toList();

/// webdav_controller.dart:493-516 (getRemoteGroupList). The original falls
/// back to generateUuidv4() only when `arr` itself is null.
List<Map<String, Object?>> legacyParseGroupNames(List<String?> names) {
  final out = <Map<String, Object?>>[];
  for (final n in names) {
    final name = n?.substring(0, n.lastIndexOf('.'));
    final arr = name?.split(kGroupSeparator);
    final profileName = arr?.first ?? '';
    final uuid = arr?[1] ?? '<generated>';
    final time = int.parse(arr?[2] ?? '0');
    if (profileName.isNotEmpty) {
      out.add({'name': profileName, 'uuid': uuid, 'lastEditTime': time});
    }
  }
  return out;
}

/// webdav_controller.dart:585-596 (getQuickList).
List<int> legacyParseQuickSearchNames(List<String?> names) => names
    .where((n) => n?.startsWith(kQuickSearchFile) ?? false)
    .map((n) {
      final name = n?.substring(0, n.lastIndexOf('.'));
      final arr = name?.split(kQuickSearchSeparator);
      return int.parse(arr?[arr.length - 1] ?? '0');
    })
    .toList();

/// lib/extension.dart:561-562 (CustomProfile.syncFileName).
String legacyGroupSyncFileName(String name, String uuid, int? lastEditTime) =>
    <String>[name, uuid, '${lastEditTime ?? 0}'].join(kGroupSeparator);

/// Remote paths the app builds for each record kind.
String historyPath(String gid, int lastViewTime) =>
    '$kHistoryDtlDirPath/${gid}_$lastViewTime.json'; // :298
String historyDeletePath(String gid) => '$kHistoryDelDirPath/$gid'; // :253
String readPath(String gid) => '$kReadDirPath/$gid.json'; // :371
String groupPath(String name, String uuid, int? lastEditTime) =>
    '$kGroupDirPath/${legacyGroupSyncFileName(name, uuid, lastEditTime)}.json'; // :448
String quickSearchPath(int time) =>
    '$kSearchDirPath/${kQuickSearchFile}_$time.txt'; // :543

// ---------------------------------------------------------------------------
// Model round trips: X.fromJson(json).toJson(), reduced to the parsing rules
// of the generated models, so the simulator proves the app can read a record
// and shows what it would keep.

String? _s(Object? v) => v?.toString();
int? _i(Object? v) => v != null ? int.tryParse('$v') ?? 0 : null;
double? _d(Object? v) => v != null ? double.tryParse('$v') ?? 0.0 : null;
bool? _b(Object? v) =>
    v != null ? bool.tryParse('$v', caseSensitive: false) ?? false : null;
List<Map<String, dynamic>>? _maps(Object? v) => v != null
    ? (v as List? ?? []).map((e) => e as Map<String, dynamic>).toList()
    : null;

/// lib/models/gallery_provider.dart (fromJson/toJson). Nested lists are only
/// checked for element type here (`e as Map<String, dynamic>`).
Map<String, dynamic> legacyGalleryProviderRoundTrip(Map<String, dynamic> j) => {
      'gid': _s(j['gid']),
      'token': _s(j['token']),
      'showKey': _s(j['showKey']),
      'url': _s(j['url']),
      'imgUrl': _s(j['imgUrl']),
      'imgUrlL': _s(j['imgUrlL']),
      'imgHeight': _i(j['imgHeight']),
      'imgWidth': _i(j['imgWidth']),
      'japaneseTitle': _s(j['japaneseTitle']),
      'englishTitle': _s(j['englishTitle']),
      'category': _s(j['category']),
      'uploader': _s(j['uploader']),
      'posted': _s(j['posted']),
      'language': _s(j['language']),
      'filecount': _s(j['filecount']),
      'rating': _d(j['rating']),
      'ratingCount': _s(j['ratingCount']),
      'torrentcount': _s(j['torrentcount']),
      'torrents': _maps(j['torrents']),
      'filesize': _i(j['filesize']),
      'filesizeText': _s(j['filesizeText']),
      'visible': _s(j['visible']),
      'parent': _s(j['parent']),
      'parentHref': _s(j['parentHref']),
      'ratingFallBack': _d(j['ratingFallBack']),
      'numberOfReviews': _s(j['numberOfReviews']),
      'postTime': _s(j['postTime']),
      'favoritedCount': _s(j['favoritedCount']),
      'favTitle': _s(j['favTitle']),
      'favcat': _s(j['favcat']),
      'localFav': _b(j['localFav']),
      'simpleTags': _maps(j['simpleTags']),
      'tagsFromApi': j['tagsFromApi'] != null
          ? (j['tagsFromApi'] as List? ?? []).map((e) => e.toString()).toList()
          : null,
      'translated': _s(j['translated']),
      'tagGroup': _maps(j['tagGroup']),
      'galleryComment': _maps(j['galleryComment']),
      'galleryImages': _maps(j['galleryImages']),
      'chapter': _maps(j['chapter']),
      'apikey': _s(j['apikey']),
      'apiuid': _s(j['apiuid']),
      'isRatinged': _b(j['isRatinged']),
      'colorRating': _s(j['colorRating']),
      'archiverLink': _s(j['archiverLink']),
      'torrentLink': _s(j['torrentLink']),
      'lastViewTime': _i(j['lastViewTime']),
      'pageOfList': _i(j['pageOfList']),
      'favNote': _s(j['favNote']),
      'expunged': _b(j['expunged']),
    };

/// lib/models/gallery_cache.dart:23-37.
Map<String, dynamic> legacyGalleryCacheRoundTrip(Map<String, dynamic> j) => {
      'gid': _s(j['gid']),
      'lastIndex': _i(j['lastIndex']),
      'lastOffset': _d(j['lastOffset']),
      'columnModeVal': _s(j['columnModeVal']),
      'time': _i(j['time']),
    };

/// lib/models/custom_profile.dart:39-69 (advSearch kept as a map).
Map<String, dynamic> legacyCustomProfileRoundTrip(Map<String, dynamic> j) => {
      'uuid': j['uuid'].toString(),
      'name': j['name'].toString(),
      'searchText': j['searchText'] != null
          ? (j['searchText'] as List? ?? []).map((e) => e.toString()).toList()
          : null,
      'listTypeValue': _s(j['listTypeValue']),
      'catsTypeValue': _s(j['catsTypeValue']),
      'cats': _i(j['cats']),
      'enableAdvance': _b(j['enableAdvance']),
      'advSearchTypeValue': _s(j['advSearchTypeValue']),
      'advSearch': j['advSearch'] != null
          ? j['advSearch'] as Map<String, dynamic>
          : null,
      'listModeValue': _s(j['listModeValue']),
      'hideTab': _b(j['hideTab']),
      'aggregateGroups': j['aggregateGroups'] != null
          ? (j['aggregateGroups'] as List? ?? []).map((e) => e as String).toList()
          : null,
      'lastEditTime': _i(j['lastEditTime']),
    };

// ---------------------------------------------------------------------------
// Fabricated records. Nothing here comes from a real gallery or account:
// gids start at 1000001, tokens are 10 hex zeros plus a digit, titles say
// "Fake"/"示例"/"サンプル", UUIDs are all-zero v4 patterns.

/// Key order follows GalleryProvider.toJson; galleryComment, galleryImages
/// and tagGroup are emptied the way uploadHistory does
/// (webdav_controller.dart:284-288).
Map<String, dynamic> fakeHistory({
  required String gid,
  required String token,
  required int lastViewTime,
  required String englishTitle,
  required String japaneseTitle,
  required double rating,
}) =>
    {
      'gid': gid,
      'token': token,
      'showKey': null,
      'url': 'https://e-hentai.org/g/$gid/$token/',
      'imgUrl': 'https://ehgt.org/w/00/000/fake-cover-$gid.webp',
      'imgUrlL': null,
      'imgHeight': 300,
      'imgWidth': 212,
      'japaneseTitle': japaneseTitle,
      'englishTitle': englishTitle,
      'category': 'Doujinshi',
      'uploader': 'fake-uploader',
      'posted': '2025-01-02 03:04',
      'language': 'Chinese',
      'filecount': '24',
      'rating': rating,
      'ratingCount': '12',
      'torrentcount': '0',
      'torrents': <Object?>[],
      'filesize': null,
      'filesizeText': '12.34 MiB',
      'visible': 'Yes',
      'parent': null,
      'parentHref': null,
      'ratingFallBack': rating,
      'numberOfReviews': '3',
      'postTime': '1735787040',
      'favoritedCount': '5',
      'favTitle': null,
      'favcat': null,
      'localFav': false,
      'simpleTags': [
        {
          'text': 'language:chinese',
          'Translat': '中文',
          'color': null,
          'backgrondColor': null
        },
        {
          'text': 'other:fake tag',
          'Translat': '示例标签 "quoted" \\ slash/',
          'color': '#ffffff',
          'backgrondColor': '#000000'
        },
      ],
      'tagsFromApi': ['language:chinese', 'other:fake tag'],
      'translated': null,
      'tagGroup': <Object?>[],
      'galleryComment': <Object?>[],
      'galleryImages': <Object?>[],
      'chapter': [
        {'page': 1, 'author': null, 'title': '第一章 Fake'},
      ],
      'apikey': null,
      'apiuid': null,
      'isRatinged': false,
      'colorRating': null,
      'archiverLink': null,
      'torrentLink': null,
      'lastViewTime': lastViewTime,
      'pageOfList': null,
      'favNote': null,
      'expunged': false,
    };

/// A history detail as the app wrote it before 690502e2 ("Feat: aes",
/// 2021-08-30): plain jsonEncode of the old GalleryItem, no encryption
/// (`git show 690502e2^:lib/common/controller/webdav_controller.dart`,
/// lines 241-247). Key order follows that GalleryItem.toJson
/// (`690502e2^:lib/models/gallery_item.dart`): no parentHref, chapter,
/// favNote or expunged, and imgHeight/imgWidth were doubles, so they are
/// written as `300.0`.
Map<String, dynamic> fakePreAesGalleryItem({
  required String gid,
  required String token,
  required int lastViewTime,
}) =>
    {
      'gid': gid,
      'token': token,
      'showKey': null,
      'url': 'https://e-hentai.org/g/$gid/$token/',
      'imgUrl': 'https://ehgt.org/w/00/000/fake-cover-$gid.jpg',
      'imgUrlL': null,
      'imgHeight': 300.0,
      'imgWidth': 212.0,
      'japaneseTitle': '[示例] 2021年の古い履歴',
      'englishTitle': '[Fake] Pre-AES History Entry',
      'category': 'Manga',
      'uploader': 'fake-uploader',
      'posted': '2021-08-01 12:34',
      'language': 'Japanese',
      'filecount': '18',
      'rating': 3.5,
      'ratingCount': '7',
      'torrentcount': '0',
      'torrents': <Object?>[],
      'filesize': null,
      'filesizeText': '8.76 MiB',
      'visible': 'Yes',
      'parent': null,
      'ratingFallBack': 3.5,
      'numberOfReviews': '1',
      'postTime': '1627821240',
      'favoritedCount': '2',
      'favTitle': null,
      'favcat': null,
      'localFav': false,
      'simpleTags': [
        {
          'text': 'language:japanese',
          'Translat': '日语',
          'color': null,
          'backgrondColor': null
        },
      ],
      'tagsFromApi': ['language:japanese'],
      'translated': null,
      'tagGroup': <Object?>[],
      'galleryComment': <Object?>[],
      'galleryImages': <Object?>[],
      'apikey': null,
      'apiuid': null,
      'isRatinged': false,
      'colorRating': null,
      'archiverLink': null,
      'torrentLink': null,
      'lastViewTime': lastViewTime,
      'pageOfList': null,
    };

/// GalleryCache as uploadRead sends it: columnModeVal forced to ''
/// (webdav_controller.dart:362-364).
Map<String, dynamic> fakeReadProgress({
  required String gid,
  required int lastIndex,
  required double? lastOffset,
  required int time,
}) =>
    {
      'gid': gid,
      'lastIndex': lastIndex,
      'lastOffset': lastOffset,
      'columnModeVal': '',
      'time': time,
    };

/// CustomProfile.toJson key order.
Map<String, dynamic> fakeGroup({
  required String uuid,
  required String name,
  required List<String> searchText,
  required int lastEditTime,
  bool withAdvanceSearch = false,
}) =>
    {
      'uuid': uuid,
      'name': name,
      'searchText': searchText,
      'listTypeValue': 'gallery',
      'catsTypeValue': null,
      'cats': 0,
      'enableAdvance': withAdvanceSearch,
      'advSearchTypeValue': null,
      'advSearch': withAdvanceSearch
          ? {
              'requireGalleryTorrent': false,
              'browseExpungedGalleries': false,
              'searchWithMinRating': true,
              'minRating': 3,
              'searchBetweenPage': false,
              'startPage': '',
              'endPage': '',
              'disableCustomFilterLanguage': false,
              'disableCustomFilterUploader': false,
              'disableCustomFilterTags': false,
            }
          : null,
      'listModeValue': 'global',
      'hideTab': false,
      'aggregateGroups': null,
      'lastEditTime': lastEditTime,
    };
