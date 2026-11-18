import Foundation

/// A JSON value. Records stay close to the wire format so that fields the Swift app does not
/// model survive a download/upload round trip.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case let .object(fields) = self { fields[key] } else { nil }
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

/// Field parsing of the Flutter models' generated `fromJson`.
///
/// Scalar fields never throw on a bad type: strings use `json[k]?.toString()`, ints
/// `int.tryParse('$v') ?? 0`, doubles `double.tryParse('$v') ?? 0.0`, bools
/// `bool.tryParse('$v', caseSensitive: false) ?? false`. So a wrong scalar type becomes 0/false,
/// and an int written as `5.0` reads as 0.
///
/// List and object fields do throw: `json[k] as List?`, `e as Map<String, dynamic>`, `e as String`
/// and `json[k] as Map<String, dynamic>` fail on a wrong type (custom_profile.dart:42, 48, 51;
/// gallery_provider.dart:128, 141, 144-147), and the legacy download functions then return null
/// for the whole record. Swift is more lenient there: ``stringList(_:)`` stringifies elements,
/// a non-object `advSearch` becomes nil, and history keeps nested values as raw JSON.
enum LegacyJSON {
    static func string(_ value: JSONValue?) -> String? {
        guard let value, value != .null else { return nil }
        return dartString(value)
    }

    static func int(_ value: JSONValue?) -> Int? {
        guard let value, value != .null else { return nil }
        if case let .int(number) = value { return Int(exactly: number) ?? 0 }
        return dartIntParse(dartString(value)) ?? 0
    }

    static func double(_ value: JSONValue?) -> Double? {
        guard let value, value != .null else { return nil }
        switch value {
        case let .int(number): return Double(number)
        case let .double(number): return number
        default: return Double(dartString(value).trimmingCharacters(in: .whitespaces)) ?? 0
        }
    }

    static func bool(_ value: JSONValue?) -> Bool? {
        guard let value, value != .null else { return nil }
        if case let .bool(flag) = value { return flag }
        return dartString(value).lowercased() == "true"
    }

    /// `(json[k] as List? ?? []).map((e) => e.toString())`.
    static func stringList(_ value: JSONValue?) -> [String]? {
        guard let value, value != .null else { return nil }
        guard case let .array(items) = value else { return [] }
        return items.map(dartString)
    }

    /// `'$v'` in Dart for a decoded JSON value.
    private static func dartString(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case let .bool(flag): flag ? "true" : "false"
        case let .int(number): String(number)
        case let .double(number): number.description
        case let .string(text): text
        case let .array(items): "[" + items.map(dartString).joined(separator: ", ") + "]"
        case let .object(fields): "{" + fields.map { "\($0.key): \(dartString($0.value))" }.joined(separator: ", ") + "}"
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
            return Int(digits.dropFirst(2), radix: 16).map { $0 * sign }
        }
        guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit) else { return nil }
        return Int(digits).map { $0 * sign }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// A history entry: the JSON of `GalleryProvider` (lib/models/gallery_provider.dart, 48 keys).
/// Kept as the raw object; the typed accessors apply the legacy `fromJson` rules.
public struct LegacyHistoryRecord: Sendable, Equatable {
    public var fields: [String: JSONValue]

    public init(json: JSONValue) {
        if case let .object(fields) = json { self.fields = fields } else { fields = [:] }
    }

    public var json: JSONValue { .object(fields) }
    public var gid: String? { LegacyJSON.string(fields["gid"]) }
    public var token: String? { LegacyJSON.string(fields["token"]) }
    public var lastViewTime: Int? { LegacyJSON.int(fields["lastViewTime"]) }
    public var englishTitle: String? { LegacyJSON.string(fields["englishTitle"]) }
    public var japaneseTitle: String? { LegacyJSON.string(fields["japaneseTitle"]) }
    public var rating: Double? { LegacyJSON.double(fields["rating"]) }

    /// `uploadHistory` uploads a copy with comments, images and tag groups emptied
    /// (webdav_controller.dart:284-288).
    public func preparedForUpload() -> LegacyHistoryRecord {
        var copy = self
        for key in ["galleryComment", "galleryImages", "tagGroup"] {
            copy.fields[key] = .array([])
        }
        return copy
    }
}

/// `GalleryCache` (lib/models/gallery_cache.dart:23-37).
public struct LegacyReadProgress: Sendable, Equatable {
    public var gid: String?
    public var lastIndex: Int?
    public var lastOffset: Double?
    public var columnModeVal: String?
    /// Milliseconds since 1970 of the last page change; the merge key.
    public var time: Int?

    public init(gid: String?, lastIndex: Int?, lastOffset: Double?, columnModeVal: String?, time: Int?) {
        self.gid = gid
        self.lastIndex = lastIndex
        self.lastOffset = lastOffset
        self.columnModeVal = columnModeVal
        self.time = time
    }

    public init(json: JSONValue) {
        gid = LegacyJSON.string(json["gid"])
        lastIndex = LegacyJSON.int(json["lastIndex"])
        lastOffset = LegacyJSON.double(json["lastOffset"])
        columnModeVal = LegacyJSON.string(json["columnModeVal"])
        time = LegacyJSON.int(json["time"])
    }

    /// Same keys as `toJson`, nulls included.
    public var json: JSONValue {
        .object([
            "gid": gid.map(JSONValue.string) ?? .null,
            "lastIndex": lastIndex.map { .int(Int64($0)) } ?? .null,
            "lastOffset": lastOffset.map(JSONValue.double) ?? .null,
            "columnModeVal": columnModeVal.map(JSONValue.string) ?? .null,
            "time": time.map { .int(Int64($0)) } ?? .null,
        ])
    }
}

/// `CustomProfile` (lib/models/custom_profile.dart:39-69). `advSearch` stays raw JSON.
public struct LegacyCustomProfile: Sendable, Equatable {
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
    /// Milliseconds since 1970 of the last edit; the merge key and part of the file name.
    public var lastEditTime: Int?

    public init(
        uuid: String, name: String, searchText: [String]? = nil, listTypeValue: String? = nil,
        catsTypeValue: String? = nil, cats: Int? = nil, enableAdvance: Bool? = nil,
        advSearchTypeValue: String? = nil, advSearch: JSONValue? = nil, listModeValue: String? = nil,
        hideTab: Bool? = nil, aggregateGroups: [String]? = nil, lastEditTime: Int? = nil
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

    public init(json: JSONValue) {
        // `json['uuid'].toString()` turns a missing key into the string "null".
        uuid = LegacyJSON.string(json["uuid"]) ?? "null"
        name = LegacyJSON.string(json["name"]) ?? "null"
        searchText = LegacyJSON.stringList(json["searchText"])
        listTypeValue = LegacyJSON.string(json["listTypeValue"])
        catsTypeValue = LegacyJSON.string(json["catsTypeValue"])
        cats = LegacyJSON.int(json["cats"])
        enableAdvance = LegacyJSON.bool(json["enableAdvance"])
        advSearchTypeValue = LegacyJSON.string(json["advSearchTypeValue"])
        if case .object = json["advSearch"] { advSearch = json["advSearch"] } else { advSearch = nil }
        listModeValue = LegacyJSON.string(json["listModeValue"])
        hideTab = LegacyJSON.bool(json["hideTab"])
        aggregateGroups = LegacyJSON.stringList(json["aggregateGroups"])
        lastEditTime = LegacyJSON.int(json["lastEditTime"])
    }

    /// Same keys as `toJson`, nulls included.
    public var json: JSONValue {
        func value(_ text: String?) -> JSONValue { text.map(JSONValue.string) ?? .null }
        func value(_ number: Int?) -> JSONValue { number.map { .int(Int64($0)) } ?? .null }
        func value(_ flag: Bool?) -> JSONValue { flag.map(JSONValue.bool) ?? .null }
        func value(_ list: [String]?) -> JSONValue { list.map { .array($0.map(JSONValue.string)) } ?? .null }
        return .object([
            "uuid": .string(uuid),
            "name": .string(name),
            "searchText": value(searchText),
            "listTypeValue": value(listTypeValue),
            "catsTypeValue": value(catsTypeValue),
            "cats": value(cats),
            "enableAdvance": value(enableAdvance),
            "advSearchTypeValue": value(advSearchTypeValue),
            "advSearch": advSearch ?? .null,
            "listModeValue": value(listModeValue),
            "hideTab": value(hideTab),
            "aggregateGroups": value(aggregateGroups),
            "lastEditTime": value(lastEditTime),
        ])
    }
}

public enum LegacyCodecError: Error, Equatable, Sendable {
    case invalidUTF8
    /// The payload is JSON but not an object (`as Map<String, dynamic>` fails in the app).
    case notAnObject
}

/// File contents per record kind, as the legacy upload and download functions produce and read them.
public enum LegacyCodec {
    /// Decodes a history, reading-progress or group file: UTF-8 text, then plain JSON if it starts
    /// with `{`, otherwise ``LegacyCipher`` ciphertext.
    public static func decodeJSONPayload(_ data: Data) throws -> JSONValue {
        guard let text = String(data: data, encoding: .utf8) else { throw LegacyCodecError.invalidUTF8 }
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(try LegacyCipher.decodePayload(text).utf8))
        guard case .object = json else { throw LegacyCodecError.notAnObject }
        return json
    }

    /// JSON text, encrypted or not. Key order and number formatting differ from Dart's
    /// `jsonEncode`, which the app does not depend on.
    public static func encodeJSONPayload(_ json: JSONValue, encrypted: Bool) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = String(decoding: try encoder.encode(json), as: UTF8.self)
        return Data((encrypted ? try LegacyCipher.encrypt(text) : text).utf8)
    }

    /// `uploadHistory`: always encrypted, comments, images and tag groups emptied.
    public static func encodeHistory(_ record: LegacyHistoryRecord) throws -> Data {
        try encodeJSONPayload(record.preparedForUpload().json, encrypted: true)
    }

    /// `uploadRead`: always encrypted, `columnModeVal` cleared (webdav_controller.dart:362-368).
    public static func encodeReadProgress(_ progress: LegacyReadProgress) throws -> Data {
        var copy = progress
        copy.columnModeVal = ""
        return try encodeJSONPayload(copy.json, encrypted: true)
    }

    /// `uploadGroupProfile`: plain JSON unless `encrypted` (the app never passes `isEncrypt: true`).
    public static func encodeGroup(_ profile: LegacyCustomProfile, encrypted: Bool = false) throws -> Data {
        try encodeJSONPayload(profile.json, encrypted: encrypted)
    }

    /// `downloadGroupProfile`: name and uuid come from the file name, not the JSON
    /// (webdav_controller.dart:486).
    public static func decodeGroup(data: Data, name: String, uuid: String) throws -> LegacyCustomProfile {
        var profile = LegacyCustomProfile(json: try decodeJSONPayload(data))
        profile.name = name
        profile.uuid = uuid
        return profile
    }

    /// `uploadQuickSearch`: one entry per line, never encrypted (webdav_controller.dart:538).
    public static func encodeQuickSearch(_ texts: [String]) -> Data {
        Data(texts.joined(separator: "\n").utf8)
    }

    /// `downloadQuickSearch`: split on `\n`, drop lines that are blank after trimming, keep the
    /// rest untrimmed (webdav_controller.dart:572-577).
    public static func decodeQuickSearch(_ data: Data) throws -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { throw LegacyCodecError.invalidUTF8 }
        return text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
