import Foundation

/// A custom list group (Flutter's `CustomProfile`).
///
/// The 13 keys of the Flutter JSON are stored as they are, nil included, so that a group survives a round trip
/// through WebDAV unchanged. The typed accessors read and write them.
public struct CustomGroup: Sendable, Hashable, Codable, Identifiable {
    public var uuid: String
    public var name: String
    public var searchText: [String]?
    public var listTypeValue: String?
    public var catsTypeValue: String?
    public var cats: Int?
    public var enableAdvance: Bool?
    public var advSearchTypeValue: String?
    public var advSearch: JSONValue?
    public var listModeValue: String?
    public var hideTab: Bool?
    public var aggregateGroups: [String]?
    public var lastEditTime: Int?

    public var id: String { uuid }

    public init(
        uuid: String, name: String, searchText: [String]? = nil, listTypeValue: String? = nil,
        catsTypeValue: String? = nil, cats: Int? = nil, enableAdvance: Bool? = nil, advSearchTypeValue: String? = nil,
        advSearch: JSONValue? = nil, listModeValue: String? = nil, hideTab: Bool? = nil,
        aggregateGroups: [String]? = nil, lastEditTime: Int? = nil
    ) {
        self.uuid = uuid
        self.name = name
        self.searchText = searchText
        self.listTypeValue = listTypeValue
        self.catsTypeValue = catsTypeValue
        self.cats = cats
        self.enableAdvance = enableAdvance
        self.advSearchTypeValue = advSearchTypeValue
        self.advSearch = advSearch
        self.listModeValue = listModeValue
        self.hideTab = hideTab
        self.aggregateGroups = aggregateGroups
        self.lastEditTime = lastEditTime
    }

    // MARK: Typed accessors

    /// The kind of list; nil or an unknown name reads as `.gallery`.
    public var listType: GroupListType {
        get { listTypeValue.flatMap(GroupListType.init(rawValue:)) ?? .gallery }
        set { listTypeValue = newValue.rawValue }
    }

    /// The layout of this group; nil follows the global setting ("global", nil and unknown names all read as nil).
    public var listStyle: ListStyle? {
        get { listModeValue.flatMap(ListStyle.init(rawValue:)) }
        set { listModeValue = newValue?.rawValue ?? "global" }
    }

    /// The excluded categories (`cats`).
    public var categories: CategoryMask? {
        get { cats.map(CategoryMask.init(rawValue:)) }
        set { cats = newValue?.rawValue }
    }

    /// The advanced search options in `advSearch`; keys this type does not know are kept on write.
    ///
    /// Reading gives nil unless `advSearch` is an object. Writing nil clears `advSearch`. Reading does not look at
    /// `enableAdvance`, and writing does not change it.
    public var advancedSearch: AdvancedSearch? {
        get {
            guard case .object(let object) = advSearch else { return nil }
            var search = AdvancedSearch()
            search.requireTorrent = Self.flag(object["requireGalleryTorrent"])
            search.showExpunged = Self.flag(object["browseExpungedGalleries"])
            if Self.flag(object["searchWithMinRating"]) {
                let rating = Self.integer(object["minRating"]) ?? 0
                // Flutter stores null for 2 stars; null and out-of-range values read as 2.
                search.minimumRating = (2...5).contains(rating) ? rating : 2
            }
            if Self.flag(object["searchBetweenPage"]) {
                search.pageRange = PageRange(
                    from: Self.pageBound(object["startPage"]), to: Self.pageBound(object["endPage"]))
            }
            search.disableLanguageFilter = Self.flag(object["disableCustomFilterLanguage"])
            search.disableUploaderFilter = Self.flag(object["disableCustomFilterUploader"])
            search.disableTagFilter = Self.flag(object["disableCustomFilterTags"])
            return search
        }
        set {
            guard let search = newValue else {
                advSearch = nil
                return
            }
            var object: [String: JSONValue] = [:]
            if case .object(let existing) = advSearch { object = existing }
            object["requireGalleryTorrent"] = .bool(search.requireTorrent)
            object["browseExpungedGalleries"] = .bool(search.showExpunged)
            object["searchWithMinRating"] = .bool(search.minimumRating != nil)
            if let rating = search.minimumRating {
                object["minRating"] = .number(Double(rating))
            } else if object["minRating"] == nil {
                object["minRating"] = .number(2)
            }
            object["searchBetweenPage"] = .bool(search.pageRange != nil)
            if let range = search.pageRange {
                object["startPage"] = .string(range.from.map(String.init) ?? "")
                object["endPage"] = .string(range.to.map(String.init) ?? "")
            } else {
                if object["startPage"] == nil { object["startPage"] = .string("") }
                if object["endPage"] == nil { object["endPage"] = .string("") }
            }
            object["disableCustomFilterLanguage"] = .bool(search.disableLanguageFilter)
            object["disableCustomFilterUploader"] = .bool(search.disableUploaderFilter)
            object["disableCustomFilterTags"] = .bool(search.disableTagFilter)
            advSearch = .object(object)
        }
    }

    private static func flag(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        return LegacyJSON.bool(value)
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard let value, value != .null else { return nil }
        return LegacyJSON.int(value)
    }

    /// A page bound: trimmed, 1 to 9 ASCII digits, as `AdvancedSearchParser` reads one.
    private static func pageBound(_ value: JSONValue?) -> Int? {
        guard let value, value != .null else { return nil }
        let text = LegacyJSON.string(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.wholeMatch(of: /[0-9]{1,9}/) != nil else { return nil }
        return Int(text)
    }

    // MARK: Defaults

    /// The groups a first launch starts with (Flutter's `defaultProfile`), named for the language.
    ///
    /// Chinese picks Simplified or Traditional names from the script subtag (`hans`, `hant`), and only without a
    /// script from the region (`tw`, `hk`, `mo` are Traditional). This slightly corrects Flutter, which picks by arb
    /// `zh_CN` or `zh_TW`, because an iOS preferred language always carries a script.
    public static func defaults(
        languageCode: String, makeID: () -> String = { UUID().uuidString.lowercased() }
    ) -> [CustomGroup] {
        let normalized = languageCode.lowercased().replacingOccurrences(of: "_", with: "-")
        let parts = normalized.split(separator: "-").map(String.init)
        let isChinese = normalized.hasPrefix("zh")
        let names: (popular: String, gallery: String, watched: String)
        if isChinese {
            let traditional: Bool
            if parts.contains("hans") {
                traditional = false
            } else if parts.contains("hant") {
                traditional = true
            } else {
                traditional = !Set(parts).isDisjoint(with: ["tw", "hk", "mo"])
            }
            names = traditional ? ("熱門", "畫廊", "關注") : ("热门", "画廊", "订阅")
        } else if normalized.hasPrefix("ja") {
            names = ("人気", "ギャラリー", "登録")
        } else if normalized.hasPrefix("ko") {
            names = ("인기", "갤러리", "Watched")
        } else if normalized.hasPrefix("ru") {
            names = ("Популярное", "Галерея", "Отслеживаемое")
        } else {
            names = ("Popular", "Gallery", "Watched")
        }
        var groups = [
            CustomGroup(uuid: makeID(), name: names.popular, listTypeValue: GroupListType.popular.rawValue),
            CustomGroup(uuid: makeID(), name: names.gallery, listTypeValue: GroupListType.gallery.rawValue),
            CustomGroup(uuid: makeID(), name: names.watched, listTypeValue: GroupListType.watched.rawValue),
        ]
        if isChinese {
            groups.append(CustomGroup(uuid: makeID(), name: "汉语", searchText: ["l:chinese"]))
        }
        groups.append(CustomGroup(uuid: makeID(), name: "Anthology", searchText: ["o:anthology"]))
        return groups
    }

    // MARK: Codable

    private static let keys = [
        "uuid", "name", "searchText", "listTypeValue", "catsTypeValue", "cats", "enableAdvance", "advSearchTypeValue",
        "advSearch", "listModeValue", "hideTab", "aggregateGroups", "lastEditTime",
    ]

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ name: String) { stringValue = name }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Reads as Flutter's `CustomProfile.fromJson` does: a wrong type never throws, it reads as a default; unknown
    /// top-level keys are dropped. See `LegacyJSON`.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.singleValueContainer().decode([String: JSONValue].self)
        func present(_ key: String) -> JSONValue? {
            guard let value = fields[key], value != .null else { return nil }
            return value
        }
        uuid = present("uuid").map(LegacyJSON.string) ?? "null"
        name = present("name").map(LegacyJSON.string) ?? "null"
        searchText = present("searchText").map(LegacyJSON.stringList)
        listTypeValue = present("listTypeValue").map(LegacyJSON.string)
        catsTypeValue = present("catsTypeValue").map(LegacyJSON.string)
        cats = present("cats").map(LegacyJSON.int)
        enableAdvance = present("enableAdvance").map(LegacyJSON.bool)
        advSearchTypeValue = present("advSearchTypeValue").map(LegacyJSON.string)
        if case .object = fields["advSearch"] { advSearch = fields["advSearch"] } else { advSearch = nil }
        listModeValue = present("listModeValue").map(LegacyJSON.string)
        hideTab = present("hideTab").map(LegacyJSON.bool)
        aggregateGroups = present("aggregateGroups").map(LegacyJSON.stringList)
        lastEditTime = present("lastEditTime").map(LegacyJSON.int)
    }

    /// Writes all 13 keys; nil is written as null.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(uuid, forKey: Key("uuid"))
        try container.encode(name, forKey: Key("name"))
        try container.encode(searchText, forKey: Key("searchText"))
        try container.encode(listTypeValue, forKey: Key("listTypeValue"))
        try container.encode(catsTypeValue, forKey: Key("catsTypeValue"))
        try container.encode(cats, forKey: Key("cats"))
        try container.encode(enableAdvance, forKey: Key("enableAdvance"))
        try container.encode(advSearchTypeValue, forKey: Key("advSearchTypeValue"))
        try container.encode(advSearch, forKey: Key("advSearch"))
        try container.encode(listModeValue, forKey: Key("listModeValue"))
        try container.encode(hideTab, forKey: Key("hideTab"))
        try container.encode(aggregateGroups, forKey: Key("aggregateGroups"))
        try container.encode(lastEditTime, forKey: Key("lastEditTime"))
    }
}

/// Field reading of the Flutter models' generated `fromJson`: scalar fields never throw, a wrong type reads as 0,
/// false or the Dart string form (`'$v'`).
private enum LegacyJSON {
    static func string(_ value: JSONValue) -> String { dartString(value) }

    /// A whole number is used as is; a fraction reads as 0; a string goes through `int.tryParse`; anything else is 0.
    static func int(_ value: JSONValue) -> Int {
        if case .number(let number) = value {
            guard number.rounded() == number, let exact = Int(exactly: number) else { return 0 }
            return exact
        }
        return dartIntParse(dartString(value)) ?? 0
    }

    /// A boolean as is; any other value is true only if its string form is "true", ignoring case.
    static func bool(_ value: JSONValue) -> Bool {
        if case .bool(let flag) = value { return flag }
        return dartString(value).lowercased() == "true"
    }

    /// A non-array reads as []; every element becomes its string form.
    static func stringList(_ value: JSONValue) -> [String] {
        guard case .array(let items) = value else { return [] }
        return items.map(dartString)
    }

    /// `'$v'` in Dart for a decoded JSON value; whole numbers carry no fraction.
    private static func dartString(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let flag): flag ? "true" : "false"
        case .number(let number):
            if number.rounded() == number, let exact = Int64(exactly: number) { String(exact) } else { number.description }
        case .string(let text): text
        case .array(let items): "[" + items.map(dartString).joined(separator: ", ") + "]"
        case .object(let fields):
            "{" + fields.map { "\($0.key): \(dartString($0.value))" }.joined(separator: ", ") + "}"
        }
    }

    /// `int.tryParse`: optional sign, decimal digits or a `0x` hex literal, surrounding whitespace allowed.
    private static func dartIntParse(_ text: String) -> Int? {
        var digits = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var sign = 1
        if let first = digits.first, first == "+" || first == "-" {
            sign = first == "-" ? -1 : 1
            digits = digits.dropFirst()
        }
        if digits.hasPrefix("0x") || digits.hasPrefix("0X") {
            let hex = digits.dropFirst(2)
            guard !hex.isEmpty, hex.allSatisfy(\.isHexDigit) else { return nil }
            return Int(hex, radix: 16).map { $0 * sign }
        }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits).map { $0 * sign }
    }
}
