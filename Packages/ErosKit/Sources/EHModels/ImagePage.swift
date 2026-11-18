import Foundation

/// One page of a gallery as the reader needs it: where its image is, and what a later request for the page needs.
///
/// Read from an image page (`/s/<key>/<gid>-<page>`), a `showpage` answer of `api.php`, or an `imagedispatch` answer
/// (the multi-page viewer's). Each source fills a different set of the optional fields; see the parsers.
public struct ImagePageInfo: Sendable, Equatable, Codable {
    /// The gallery's id.
    public var gid: Int?
    /// The gallery's token; `imagedispatch` answers do not give it.
    public var token: String?
    /// The page's number, 1-based.
    public var pageIndex: Int
    /// The gallery's number of pages, when the source shows it.
    public var pageCount: Int?
    /// The image to show: an H@H node's address, or the 509 placeholder (`isBandwidthExceeded`).
    public var imageURL: URL
    /// The image's size in pixels.
    public var imageSize: ImageSize?
    /// The original file's name.
    public var fileName: String?
    /// The shown image's file size as the site writes it ("393.4 KiB").
    public var fileSizeText: String?
    /// The original file (the `/fullimg/` link); downloading it costs image quota.
    public var originalImageURL: URL?
    /// The token that asks for the image from another source (`nl=` of the image page, `nl` of `imagedispatch`).
    public var reloadToken: String?
    /// The key `showpage` requests need; only image pages (HTML) give it.
    public var showKey: String?
    /// The page's image key (the `<key>` of `/s/<key>/<gid>-<page>`); only `showpage` answers give it (`k`).
    public var imageKey: String?
    /// The image is the site's 509 placeholder: the image quota is used up. True when `imageURL`'s host is
    /// `ehgt.org`, `e-hentai.org` or `exhentai.org` (or a subdomain of one) and its path ends with `/509.gif` or
    /// `/509s.gif`, as the Flutter `EHConst.REG_509_URL`; an H@H node's image (`*.hath.network`) never is, whatever
    /// its file name.
    public var isBandwidthExceeded: Bool

    public init(
        gid: Int?,
        token: String?,
        pageIndex: Int,
        pageCount: Int?,
        imageURL: URL,
        imageSize: ImageSize?,
        fileName: String?,
        fileSizeText: String?,
        originalImageURL: URL?,
        reloadToken: String?,
        showKey: String?,
        imageKey: String?,
        isBandwidthExceeded: Bool
    ) {
        self.gid = gid
        self.token = token
        self.pageIndex = pageIndex
        self.pageCount = pageCount
        self.imageURL = imageURL
        self.imageSize = imageSize
        self.fileName = fileName
        self.fileSizeText = fileSizeText
        self.originalImageURL = originalImageURL
        self.reloadToken = reloadToken
        self.showKey = showKey
        self.imageKey = imageKey
        self.isBandwidthExceeded = isBandwidthExceeded
    }
}

/// One page of the multi-page viewer's list (`imagelist` of `/mpv/<gid>/<token>/`).
public struct MPVImage: Sendable, Hashable, Codable {
    /// The original file's name (`n`).
    public let name: String
    /// The page's image key (`k`), for `imagedispatch` requests.
    public let key: String
    /// The thumbnail as the viewer's script gets it (`t`): the sprite's address in parentheses and its offsets,
    /// kept as written.
    public let thumbnail: String

    public init(name: String, key: String, thumbnail: String) {
        self.name = name
        self.key = key
        self.thumbnail = thumbnail
    }
}

/// The multi-page viewer page (`/mpv/<gid>/<token>/`): what `imagedispatch` requests need.
public struct MPVInfo: Sendable, Equatable, Codable {
    /// The gallery's id.
    public var gid: Int
    /// The key every `imagedispatch` request of this gallery sends.
    public var mpvKey: String
    /// The gallery's number of pages.
    public var pageCount: Int
    /// Every page, in order.
    public var images: [MPVImage]

    public init(gid: Int, mpvKey: String, pageCount: Int, images: [MPVImage]) {
        self.gid = gid
        self.mpvKey = mpvKey
        self.pageCount = pageCount
        self.images = images
    }
}
