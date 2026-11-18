/// The Flutter app's remote directory tree and file naming (webdav_controller.dart:16-31).
///
/// All paths are relative to the user's WebDAV base URL. The tree is:
///
/// ```
/// /fehviewer/history/s/<gid>_<lastViewTime>.json     history detail, AES
/// /fehviewer/history/del/<gid>                        deletion flag, empty file
/// /fehviewer/read/<gid>.json                          reading progress, AES
/// /fehviewer/group/<name>‖@‖<uuid>‖@‖<lastEditTime>.json   custom group, plain JSON
/// /fehviewer/search/quickSearch_<time>.txt            quick search, plain text
/// ```
///
/// Parsing accepts exactly the names the legacy app can parse *and* download again: the app
/// rebuilds the download path from the parsed parts, so a name such as `1_0005.json` parses
/// to gid 1, time 5 and is then fetched as `1_5.json`, which does not exist. Names the app
/// would crash on (no extension, non-numeric time) are ignored instead of failing the sync.
public enum LegacyLayout {
    public enum Entry: Hashable, Sendable {
        /// `uploadHistory` (webdav_controller.dart:297-298); time is `GalleryProvider.lastViewTime`.
        case history(gid: String, lastViewTime: Int)
        /// `updateRemoveFlg` (webdav_controller.dart:252-254). The app no longer calls it.
        case historyDeletion(gid: String)
        /// `uploadRead` (webdav_controller.dart:371).
        case readProgress(gid: String)
        /// `CustomProfile.syncFileName` (extension.dart:561-562); time is `lastEditTime ?? 0`.
        case group(name: String, uuid: String, lastEditTime: Int)
        /// `uploadQuickSearch` (webdav_controller.dart:543); time is the last local edit.
        case quickSearch(time: Int)
    }

    public static let rootDirectory = "/fehviewer"
    public static let historyDirectory = "/fehviewer/history"
    public static let historyDetailDirectory = "/fehviewer/history/s"
    public static let historyDeletionDirectory = "/fehviewer/history/del"
    public static let readProgressDirectory = "/fehviewer/read"
    public static let groupDirectory = "/fehviewer/group"
    public static let quickSearchDirectory = "/fehviewer/search"
    /// `kGroupSeparator`: U+2016 DOUBLE VERTICAL LINE, `@`, U+2016.
    public static let groupSeparator = "\u{2016}@\u{2016}"
    public static let quickSearchFilePrefix = "quickSearch"
    public static let quickSearchSeparator = "_"

    /// Directories `initClient` checks and creates, in its order (webdav_controller.dart:198-202).
    public static let startupDirectories = [
        historyDetailDirectory, historyDeletionDirectory, readProgressDirectory, groupDirectory, quickSearchDirectory,
    ]

    public static func path(for entry: Entry) -> String {
        "\(directory(of: entry))/\(fileName(for: entry))"
    }

    public static func directory(of entry: Entry) -> String {
        switch entry {
        case .history: historyDetailDirectory
        case .historyDeletion: historyDeletionDirectory
        case .readProgress: readProgressDirectory
        case .group: groupDirectory
        case .quickSearch: quickSearchDirectory
        }
    }

    public static func fileName(for entry: Entry) -> String {
        switch entry {
        case let .history(gid, time): "\(gid)_\(time).json"
        case let .historyDeletion(gid): gid
        case let .readProgress(gid): "\(gid).json"
        case let .group(name, uuid, time): [name, uuid, String(time)].joined(separator: groupSeparator) + ".json"
        case let .quickSearch(time): "\(quickSearchFilePrefix)\(quickSearchSeparator)\(time).txt"
        }
    }

    /// Parses a remote path such as `/fehviewer/read/1000001.json`.
    public static func entry(path: String) -> Entry? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        return entry(directory: String(path[..<slash]), fileName: String(path[path.index(after: slash)...]))
    }

    /// Parses a file name listed in one of the legacy directories.
    public static func entry(directory: String, fileName name: String) -> Entry? {
        switch directory {
        case historyDetailDirectory:
            // getRemoteHistoryList (webdav_controller.dart:256-271).
            guard let base = name.dropSuffix(".json") else { return nil }
            let parts = base.components(separatedBy: "_")
            guard parts.count == 2, !parts[0].isEmpty, let time = canonicalInt(parts[1]), time > 0 else { return nil }
            return .history(gid: parts[0], lastViewTime: time)
        case historyDeletionDirectory:
            // getRemotDeleteList (webdav_controller.dart:240-250) keeps every name.
            return name.isEmpty ? nil : .historyDeletion(gid: name)
        case readProgressDirectory:
            // getRemotReadList (webdav_controller.dart:414-426).
            guard let gid = name.dropSuffix(".json"), !gid.isEmpty else { return nil }
            return .readProgress(gid: gid)
        case groupDirectory:
            // getRemoteGroupList (webdav_controller.dart:493-516) skips empty names.
            guard let base = name.dropSuffix(".json") else { return nil }
            let parts = base.components(separatedBy: groupSeparator)
            guard parts.count == 3, !parts[0].isEmpty, let time = canonicalInt(parts[2]) else { return nil }
            return .group(name: parts[0], uuid: parts[1], lastEditTime: time)
        case quickSearchDirectory:
            // getQuickList (webdav_controller.dart:585-596).
            guard let base = name.dropSuffix(".txt"),
                  let digits = base.dropPrefix(quickSearchFilePrefix + quickSearchSeparator),
                  let time = canonicalInt(digits) else { return nil }
            return .quickSearch(time: time)
        default:
            return nil
        }
    }

    /// A non-negative decimal that prints back to the same text, so the rebuilt name matches.
    private static func canonicalInt(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let value = Int(text), String(value) == text else { return nil }
        return value
    }
}

private extension String {
    func dropSuffix(_ suffix: String) -> String? {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : nil
    }

    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
