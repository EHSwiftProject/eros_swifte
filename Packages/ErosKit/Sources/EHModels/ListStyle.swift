/// How a gallery list is laid out; raw values are the names of Flutter's `ListModeEnum`.
public enum ListStyle: String, Sendable, Codable, CaseIterable {
    case list, simpleList, waterfall, waterfallLarge, grid
}

/// Which kind of list a custom group shows; raw values are the names Flutter's `GroupType` writes.
public enum GroupListType: String, Sendable, Codable, CaseIterable {
    case gallery, watched, popular
}
