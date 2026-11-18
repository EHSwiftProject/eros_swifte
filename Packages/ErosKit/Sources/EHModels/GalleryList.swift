import Foundation

/// The colors a list page gives a tag (the site colors the tags of the account's My Tags), each "#rrggbb" in lower
/// case; nil when the style does not give that color.
public struct TagColors: Sendable, Hashable, Codable {
    /// Text color.
    public let text: String?
    /// Border color.
    public let border: String?
    /// Background color.
    public let background: String?

    public init(text: String?, border: String?, background: String?) {
        self.text = text
        self.border = border
        self.background = background
    }
}

/// A tag as a list row shows it.
public struct ListTag: Sendable, Hashable, Codable {
    /// The tag.
    public let tag: TagRef
    /// The colors the page gives it, or nil when it has no style.
    public let colors: TagColors?

    public init(tag: TagRef, colors: TagColors?) {
        self.tag = tag
        self.colors = colors
    }
}

/// One gallery of a list page (front page, search, favorites, watched, toplists, …), as its Compact row shows it.
public struct GallerySummary: Sendable, Hashable, Codable {
    /// The gallery.
    public var id: GalleryID
    /// The title, entities decoded.
    public var title: String
    /// The category, or nil for a name this app does not know.
    public var category: GalleryCategory?
    /// The cover thumbnail.
    public var coverURL: URL?
    /// The size the page shows the cover at.
    public var coverSize: ImageSize?
    /// The tags, in page order.
    public var tags: [ListTag]
    /// When the gallery was posted (UTC).
    public var postedAt: Date?
    /// The average rating, 0…5 in steps of 0.5; 0 when the page shows none.
    public var rating: Double
    /// Whether the stars show the account's own rating rather than the average.
    public var isRatedByUser: Bool
    /// The account's favorites category (0…9) the gallery is in, or nil.
    public var favoriteSlot: Int?
    /// The name of that category, as the page gives it.
    public var favoriteName: String?
    /// The account's note on the favorite.
    public var favoriteNote: String?
    /// The uploader's name, or nil when the list has no uploader column (favorites).
    public var uploader: String?
    /// Whether the page shows the uploader faded (an `opacity` style).
    public var isUploaderDimmed: Bool
    /// The number of pages.
    public var pageCount: Int?
    /// Whether the posted date is struck through (the gallery is expunged).
    public var isExpunged: Bool

    public init(
        id: GalleryID,
        title: String,
        category: GalleryCategory?,
        coverURL: URL?,
        coverSize: ImageSize?,
        tags: [ListTag],
        postedAt: Date?,
        rating: Double,
        isRatedByUser: Bool,
        favoriteSlot: Int?,
        favoriteName: String?,
        favoriteNote: String?,
        uploader: String?,
        isUploaderDimmed: Bool,
        pageCount: Int?,
        isExpunged: Bool
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.coverURL = coverURL
        self.coverSize = coverSize
        self.tags = tags
        self.postedAt = postedAt
        self.rating = rating
        self.isRatedByUser = isRatedByUser
        self.favoriteSlot = favoriteSlot
        self.favoriteName = favoriteName
        self.favoriteNote = favoriteNote
        self.uploader = uploader
        self.isUploaderDimmed = isUploaderDimmed
        self.pageCount = pageCount
        self.isExpunged = isExpunged
    }
}

/// One of the account's ten favorites categories, as the bar on favorites.php shows it.
public struct FavoriteFolderSummary: Sendable, Hashable, Codable {
    /// The category's number, 0…9.
    public let index: Int
    /// The category's name.
    public let name: String
    /// How many galleries it holds.
    public let count: Int

    public init(index: Int, name: String, count: Int) {
        self.index = index
        self.name = name
        self.count = count
    }
}

/// How favorites.php orders the galleries.
public enum FavoritesOrder: String, Sendable, Codable {
    /// By when they were added to favorites.
    case favoritedTime
    /// By when they were posted.
    case postedTime
}

/// A parsed gallery list page.
public struct GalleryListPage: Sendable, Equatable, Codable {
    /// The galleries, in page order.
    public var items: [GallerySummary]
    /// Rows that looked like galleries but lacked a gallery link or a title.
    public var skippedRowCount: Int
    /// The display mode the page says it is in; nil when it has no selector (empty results, toplists).
    public var displayMode: ListDisplayMode?
    /// The `prev=` value of the page's "Prev" link, or nil when there is none.
    public var previousCursor: String?
    /// The `next=` value of the page's "Next" link, or nil when there is none.
    public var nextCursor: String?
    /// The 0-based index of this page, for pages with numbered pages (toplists).
    public var pageIndex: Int?
    /// How many numbered pages there are (toplists).
    public var pageCount: Int?
    /// The text above the results ("Found about … results."), or nil.
    public var resultSummary: String?
    /// How many galleries the account's filters hid from the page ("Filtered N galleries"), or nil.
    public var filteredCount: Int?
    /// Whether an image lookup says its similarity scan was disabled.
    public var similarityScanDisabled: Bool
    /// The favorites categories (favorites.php only; empty elsewhere).
    public var favoriteFolders: [FavoriteFolderSummary]
    /// How favorites.php orders the galleries; nil on pages without that control.
    public var favoritesOrder: FavoritesOrder?

    public init(
        items: [GallerySummary],
        skippedRowCount: Int,
        displayMode: ListDisplayMode?,
        previousCursor: String?,
        nextCursor: String?,
        pageIndex: Int?,
        pageCount: Int?,
        resultSummary: String?,
        filteredCount: Int?,
        similarityScanDisabled: Bool,
        favoriteFolders: [FavoriteFolderSummary],
        favoritesOrder: FavoritesOrder?
    ) {
        self.items = items
        self.skippedRowCount = skippedRowCount
        self.displayMode = displayMode
        self.previousCursor = previousCursor
        self.nextCursor = nextCursor
        self.pageIndex = pageIndex
        self.pageCount = pageCount
        self.resultSummary = resultSummary
        self.filteredCount = filteredCount
        self.similarityScanDisabled = similarityScanDisabled
        self.favoriteFolders = favoriteFolders
        self.favoritesOrder = favoritesOrder
    }
}
