import Foundation

/// How firmly a tag is attached to a gallery, as the detail page draws its box.
public enum TagStrength: String, Sendable, Codable {
    /// A solid border (`div.gt`): voted in.
    case solid
    /// A dashed border (`div.gtl`): not yet confirmed by votes.
    case dashed
    /// A faint tag (`div.gtw`): voted down to weak.
    case weak
}

/// The account's vote on a tag, as the detail page marks its link.
public enum TagVote: Int, Sendable, Codable {
    /// Voted down (`a.tdn`).
    case down = -1
    /// No vote.
    case none = 0
    /// Voted up (`a.tup`).
    case up = 1
}

/// A tag as a gallery's tag list shows it.
public struct DetailTag: Sendable, Hashable, Codable {
    /// The tag; its namespace is the group's.
    public let tag: TagRef
    /// How firmly it is attached.
    public let strength: TagStrength
    /// The account's vote on it.
    public let vote: TagVote

    public init(tag: TagRef, strength: TagStrength, vote: TagVote) {
        self.tag = tag
        self.strength = strength
        self.vote = vote
    }
}

/// One row of a gallery's tag list: a namespace and its tags, in page order.
public struct TagGroup: Sendable, Hashable, Codable {
    /// The namespace as the row names it, without the trailing ":".
    public let namespace: String
    /// The tags of the row.
    public let tags: [DetailTag]

    public init(namespace: String, tags: [DetailTag]) {
        self.namespace = namespace
        self.tags = tags
    }
}

/// A comment on a gallery page.
public struct GalleryComment: Sendable, Hashable, Codable {
    /// The comment id (from `div.c6`'s id `comment_<id>`); 0 for the uploader comment.
    public let id: Int
    /// The poster's name.
    public let posterName: String
    /// The poster's forum member id, when the page links to the profile.
    public let posterMemberID: Int?
    /// When the comment was posted (UTC).
    public let postedAt: Date?
    /// The comment's score; nil for the uploader comment, which has none.
    public let score: Int?
    /// Whether this is the uploader's comment.
    public let isUploaderComment: Bool
    /// Whether the account may vote on it.
    public let canVote: Bool
    /// Whether the account may edit it (its own comment).
    public let canEdit: Bool
    /// The account's vote on it: -1, 0 or 1.
    public let userVote: Int
    /// The inner HTML of the comment body (`div.c6`), as the page has it; links are not added and nothing is removed.
    public let bodyHTML: String
    /// The lines of the score breakdown (`div.c7`): the base score first, then one per voter shown.
    public let scoreDetails: [String]

    public init(
        id: Int,
        posterName: String,
        posterMemberID: Int?,
        postedAt: Date?,
        score: Int?,
        isUploaderComment: Bool,
        canVote: Bool,
        canEdit: Bool,
        userVote: Int,
        bodyHTML: String,
        scoreDetails: [String]
    ) {
        self.id = id
        self.posterName = posterName
        self.posterMemberID = posterMemberID
        self.postedAt = postedAt
        self.score = score
        self.isUploaderComment = isUploaderComment
        self.canVote = canVote
        self.canEdit = canEdit
        self.userVote = userVote
        self.bodyHTML = bodyHTML
        self.scoreDetails = scoreDetails
    }
}

/// The image a thumbnail cell shows.
public enum ThumbnailImage: Sendable, Hashable, Codable {
    /// A cell of a sprite sheet: the sheet's URL, the cell's size and its horizontal offset into the sheet (pixels
    /// from the left edge). The current thumbnails (`#gdt > a > div`) and the legacy small ones (`div.gdtm`).
    case sprite(url: URL, size: ImageSize, offsetX: Int)
    /// An image of its own, with the original image's size when its URL tells it. The legacy large thumbnails
    /// (`div.gdtl`).
    case single(url: URL, originalSize: ImageSize?)
}

/// One thumbnail of a gallery page.
public struct GalleryThumbnail: Sendable, Hashable, Codable {
    /// The page's number in the gallery, 1-based.
    public let pageIndex: Int
    /// The image page it links to (`/s/<key>/<gid>-<page>`).
    public let pageURL: URL
    /// What the cell shows.
    public let image: ThumbnailImage

    public init(pageIndex: Int, pageURL: URL, image: ThumbnailImage) {
        self.pageIndex = pageIndex
        self.pageURL = pageURL
        self.image = image
    }
}

/// A parsed gallery page (`/g/<gid>/<token>/`, any thumbnail page `?p=<n>`).
public struct GalleryDetail: Sendable, Equatable, Codable {
    /// The gallery, from the page script.
    public var id: GalleryID
    /// The title (`#gn`), entities decoded.
    public var title: String
    /// The Japanese title (`#gj`), or nil when the page leaves it empty.
    public var japaneseTitle: String?
    /// The category, or nil for a name this app does not know.
    public var category: GalleryCategory?
    /// The uploader's name.
    public var uploader: String?
    /// The cover image.
    public var coverURL: URL?
    /// When the gallery was posted (UTC).
    public var postedAt: Date?
    /// The gallery this one replaces, or nil ("None").
    public var parent: GalleryID?
    /// The "Visible" row as the page says it ("Yes", or "No" with a reason).
    public var visibility: String?
    /// The language as the page names it, without the "TR" (translated) mark.
    public var language: String?
    /// The total file size as the page writes it ("12.34 MiB").
    public var fileSizeText: String?
    /// The number of pages.
    public var pageCount: Int?
    /// How many accounts have favorited it.
    public var favoritedCount: Int?
    /// The average rating, or nil when the page gives none.
    public var ratingAverage: Double?
    /// How many ratings the average is of.
    public var ratingCount: Int?
    /// The rating the stars show (the account's own when it has rated); 0 when the page gives none.
    public var displayedRating: Double
    /// Whether the stars show the account's own rating.
    public var isRatedByUser: Bool
    /// The account's favorites category (0…9) the gallery is in, or nil.
    public var favoriteSlot: Int?
    /// The name of that category, as the page gives it.
    public var favoriteName: String?
    /// The tag list, one group per namespace row.
    public var tagGroups: [TagGroup]
    /// The comments the page shows, in page order.
    public var comments: [GalleryComment]
    /// Whether the page offers to show more comments than it does.
    public var hasMoreComments: Bool
    /// The thumbnails of this thumbnail page. A gallery page always shows at least one, so an empty list while
    /// `pageCount > 0` means the thumbnails could not be read (the site may have changed their markup); the rest of
    /// the page was read all the same, and the app should say the thumbnails failed to load.
    public var thumbnails: [GalleryThumbnail]
    /// The 0-based index of this thumbnail page.
    public var thumbnailPageIndex: Int
    /// How many thumbnail pages the gallery has.
    public var thumbnailPageCount: Int
    /// The account id the page's API calls use (`apiuid`).
    public var apiUID: Int?
    /// The key the page's API calls use (`apikey`).
    public var apiKey: String?
    /// How many torrents the gallery has.
    public var torrentCount: Int
    /// The archive download popup.
    public var archiverURL: URL?

    public init(
        id: GalleryID,
        title: String,
        japaneseTitle: String?,
        category: GalleryCategory?,
        uploader: String?,
        coverURL: URL?,
        postedAt: Date?,
        parent: GalleryID?,
        visibility: String?,
        language: String?,
        fileSizeText: String?,
        pageCount: Int?,
        favoritedCount: Int?,
        ratingAverage: Double?,
        ratingCount: Int?,
        displayedRating: Double,
        isRatedByUser: Bool,
        favoriteSlot: Int?,
        favoriteName: String?,
        tagGroups: [TagGroup],
        comments: [GalleryComment],
        hasMoreComments: Bool,
        thumbnails: [GalleryThumbnail],
        thumbnailPageIndex: Int,
        thumbnailPageCount: Int,
        apiUID: Int?,
        apiKey: String?,
        torrentCount: Int,
        archiverURL: URL?
    ) {
        self.id = id
        self.title = title
        self.japaneseTitle = japaneseTitle
        self.category = category
        self.uploader = uploader
        self.coverURL = coverURL
        self.postedAt = postedAt
        self.parent = parent
        self.visibility = visibility
        self.language = language
        self.fileSizeText = fileSizeText
        self.pageCount = pageCount
        self.favoritedCount = favoritedCount
        self.ratingAverage = ratingAverage
        self.ratingCount = ratingCount
        self.displayedRating = displayedRating
        self.isRatedByUser = isRatedByUser
        self.favoriteSlot = favoriteSlot
        self.favoriteName = favoriteName
        self.tagGroups = tagGroups
        self.comments = comments
        self.hasMoreComments = hasMoreComments
        self.thumbnails = thumbnails
        self.thumbnailPageIndex = thumbnailPageIndex
        self.thumbnailPageCount = thumbnailPageCount
        self.apiUID = apiUID
        self.apiKey = apiKey
        self.torrentCount = torrentCount
        self.archiverURL = archiverURL
    }
}
