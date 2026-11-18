import Foundation

/// One gallery as the `gdata` method of `api.php` describes it.
public struct GalleryMetadata: Sendable, Equatable, Codable {
    /// The gallery id and token.
    public var id: GalleryID
    /// The title (HTML entities decoded).
    public var title: String
    /// The Japanese title, when the gallery has one.
    public var japaneseTitle: String?
    /// The category, nil when the label is not one of the ten known ones.
    public var category: GalleryCategory?
    /// The cover thumbnail.
    public var thumbnailURL: URL?
    /// The uploader's name.
    public var uploader: String?
    /// When the gallery was posted (UTC).
    public var postedAt: Date?
    /// The number of images.
    public var fileCount: Int?
    /// The size of the files in bytes.
    public var fileSize: Int?
    /// Whether the gallery is expunged.
    public var isExpunged: Bool
    /// The average rating (0 to 5).
    public var rating: Double?
    /// The number of torrents.
    public var torrentCount: Int?
    /// The tags, as "namespace:name" or "name" split into `TagRef`s.
    public var tags: [TagRef]

    public init(
        id: GalleryID, title: String, japaneseTitle: String?, category: GalleryCategory?, thumbnailURL: URL?,
        uploader: String?, postedAt: Date?, fileCount: Int?, fileSize: Int?, isExpunged: Bool, rating: Double?,
        torrentCount: Int?, tags: [TagRef]
    ) {
        self.id = id
        self.title = title
        self.japaneseTitle = japaneseTitle
        self.category = category
        self.thumbnailURL = thumbnailURL
        self.uploader = uploader
        self.postedAt = postedAt
        self.fileCount = fileCount
        self.fileSize = fileSize
        self.isExpunged = isExpunged
        self.rating = rating
        self.torrentCount = torrentCount
        self.tags = tags
    }
}

/// The answer to a gallery rating (`rategallery`).
public struct RatingResult: Sendable, Equatable, Codable {
    /// The new average rating.
    public let average: Double
    /// The account's rating.
    public let userRating: Double
    /// The number of ratings.
    public let count: Int

    public init(average: Double, userRating: Double, count: Int) {
        self.average = average
        self.userRating = userRating
        self.count = count
    }
}

/// The answer to a comment vote (`votecomment`).
public struct CommentVoteResult: Sendable, Equatable, Codable {
    /// The comment's id.
    public let commentID: Int
    /// The comment's score after the vote.
    public let score: Int
    /// The account's vote: 1 up, -1 down, 0 none.
    public let vote: Int

    public init(commentID: Int, score: Int, vote: Int) {
        self.commentID = commentID
        self.score = score
        self.vote = vote
    }
}

/// The answer to a tag vote (`taggallery`): the gallery's tag list after the vote.
public struct TagVoteResult: Sendable, Equatable, Codable {
    /// The tag rows, in page order.
    public let tagGroups: [TagGroup]

    public init(tagGroups: [TagGroup]) {
        self.tagGroups = tagGroups
    }
}
