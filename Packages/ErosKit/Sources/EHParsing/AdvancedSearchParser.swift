import EHModels
import Foundation

/// Reads and writes the advanced options of a search query.
public enum AdvancedSearchParser {
    /// The advanced options in `queryItems`; other items are ignored. A flag is set by the value `on`; when a name
    /// repeats, the last one counts (as Dart's `Uri.queryParameters`).
    ///
    /// - Unlike the Flutter `search_parser.dart`, the uploader filter is read from `f_sfu` and the tag filter from
    ///   `f_sft`, the names its own `param` writes.
    /// - `f_sr=on` with `f_srdd` outside 2 to 5 (or unreadable) sets no minimum rating.
    /// - `f_sp=on` sets a page range even when `f_spf` and `f_spt` are absent or unreadable (both bounds are then nil).
    public static func parse(queryItems: [URLQueryItem]) -> AdvancedSearch {
        var values: [String: String] = [:]
        for item in queryItems {
            values[item.name] = item.value ?? ""
        }
        func isOn(_ name: String) -> Bool {
            values[name]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "on"
        }
        func number(_ name: String) -> Int? {
            guard let text = values[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  text.wholeMatch(of: /[0-9]{1,9}/) != nil else { return nil }
            return Int(text)
        }

        var search = AdvancedSearch()
        search.requireTorrent = isOn("f_sto")
        search.showExpunged = isOn("f_sh")
        if isOn("f_sr"), let rating = number("f_srdd"), (2...5).contains(rating) {
            search.minimumRating = rating
        }
        if isOn("f_sp") {
            search.pageRange = PageRange(from: number("f_spf"), to: number("f_spt"))
        }
        search.disableLanguageFilter = isOn("f_sfl")
        search.disableUploaderFilter = isOn("f_sfu")
        search.disableTagFilter = isOn("f_sft")
        return search
    }

    /// The query items of `search`, in the order of Flutter's `ExtAdvanceSearch.param`: `f_sto`, `f_sh`, `f_sr`,
    /// `f_srdd`, `f_sp`, `f_spf`, `f_spt`, `f_sfl`, `f_sfu`, `f_sft`. Empty when nothing is set. A minimum rating
    /// outside 2 to 5 and a negative bound are left out. `advsearch=1` is added by the list query, not here.
    public static func queryItems(for search: AdvancedSearch) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if search.requireTorrent { items.append(URLQueryItem(name: "f_sto", value: "on")) }
        if search.showExpunged { items.append(URLQueryItem(name: "f_sh", value: "on")) }
        if let rating = search.minimumRating, (2...5).contains(rating) {
            items.append(URLQueryItem(name: "f_sr", value: "on"))
            items.append(URLQueryItem(name: "f_srdd", value: String(rating)))
        }
        if let range = search.pageRange {
            items.append(URLQueryItem(name: "f_sp", value: "on"))
            if let from = range.from, from >= 0 { items.append(URLQueryItem(name: "f_spf", value: String(from))) }
            if let to = range.to, to >= 0 { items.append(URLQueryItem(name: "f_spt", value: String(to))) }
        }
        if search.disableLanguageFilter { items.append(URLQueryItem(name: "f_sfl", value: "on")) }
        if search.disableUploaderFilter { items.append(URLQueryItem(name: "f_sfu", value: "on")) }
        if search.disableTagFilter { items.append(URLQueryItem(name: "f_sft", value: "on")) }
        return items
    }
}
