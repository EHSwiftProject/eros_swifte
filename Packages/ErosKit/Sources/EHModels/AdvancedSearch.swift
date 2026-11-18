/// A range of gallery page counts; a nil end is open.
public struct PageRange: Sendable, Hashable, Codable {
    /// The least page count (`f_spf`).
    public var from: Int?
    /// The greatest page count (`f_spt`).
    public var to: Int?

    public init(from: Int?, to: Int?) {
        self.from = from
        self.to = to
    }
}

/// The advanced options of a gallery search.
public struct AdvancedSearch: Sendable, Hashable, Codable {
    /// Only galleries with a torrent (`f_sto`).
    public var requireTorrent = false
    /// Include expunged galleries (`f_sh`).
    public var showExpunged = false
    /// The least rating, 2 to 5 (`f_sr` with `f_srdd`).
    public var minimumRating: Int?
    /// The page count range (`f_sp` with `f_spf` and `f_spt`).
    public var pageRange: PageRange?
    /// Do not apply the language filter of My Tags (`f_sfl`).
    public var disableLanguageFilter = false
    /// Do not apply the uploader filter of My Tags (`f_sfu`).
    public var disableUploaderFilter = false
    /// Do not apply the tag filter of My Tags (`f_sft`).
    public var disableTagFilter = false

    public init() {}
}
