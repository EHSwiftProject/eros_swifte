import Foundation

// MARK: Archiver (`archiver.php`)

/// The account's balances as the archiver popup shows them ("Current Funds"); exhentai.org does not show them.
public struct ArchiveFunds: Sendable, Equatable, Codable {
    /// Gallery Points.
    public let gp: Int
    /// Credits.
    public let credits: Int

    public init(gp: Int, credits: Int) {
        self.gp = gp
        self.credits = credits
    }
}

/// One archive the site packs for download (the popup's "Download Original Archive" or "Download Resample Archive").
public struct ArchiveDownload: Sendable, Equatable, Codable {
    /// The form's `dltype`: "org" (original) or "res" (resample); sent back to request the archive.
    public let type: String
    /// The cost as the site writes it ("Free!", "1,234 GP").
    public let costText: String
    /// The estimated size as the site writes it ("12.3 MiB").
    public let sizeText: String

    public init(type: String, costText: String, sizeText: String) {
        self.type = type
        self.costText = costText
        self.sizeText = sizeText
    }
}

/// One size the account's H@H client can download the gallery at.
public struct HathDownloadOption: Sendable, Equatable, Codable {
    /// The size as the popup names it ("Original", "1280x").
    public let resolution: String
    /// The argument of the popup's `do_hathdl('…')` ("org", "1280"); sent back as `hathdl_xres`.
    public let xres: String
    /// The estimated size as the site writes it.
    public let sizeText: String
    /// The cost as the site writes it ("Free", "123 GP").
    public let costText: String

    public init(resolution: String, xres: String, sizeText: String, costText: String) {
        self.resolution = resolution
        self.xres = xres
        self.sizeText = sizeText
        self.costText = costText
    }
}

/// The archiver popup: the account's funds, the archives on offer and the H@H download sizes.
public struct ArchiveOptions: Sendable, Equatable, Codable {
    /// The account's funds; nil when the popup has no "Current Funds" part (exhentai.org), and nil when it has one
    /// whose amounts cannot be read (the rest of the popup is still read).
    public var funds: ArchiveFunds?
    /// The archives, in page order.
    public var downloads: [ArchiveDownload]
    /// The H@H sizes the site can make, in page order; empty when the account has no H@H client.
    public var hathOptions: [HathDownloadOption]

    public init(funds: ArchiveFunds?, downloads: [ArchiveDownload], hathOptions: [HathDownloadOption]) {
        self.funds = funds
        self.downloads = downloads
        self.hathOptions = hathOptions
    }
}

// MARK: Torrents (`gallerytorrents.php`)

/// One torrent of a gallery.
public struct TorrentInfo: Sendable, Equatable, Codable {
    /// The file name the torrent downloads, as its link shows it.
    public let name: String
    /// The info hash: 40 lowercase hexadecimal digits.
    public let infoHash: String
    /// The `.torrent` file (the link's address; the tracker host of the site).
    public let downloadURL: URL
    /// When the torrent was posted, as the site writes it ("2024-01-31 12:34").
    public let postedText: String?
    /// The size as the site writes it ("123.4 MiB").
    public let sizeText: String?
    /// Seeders.
    public let seeds: Int?
    /// Peers.
    public let peers: Int?
    /// Completed downloads.
    public let downloads: Int?
    /// The uploader's name.
    public let uploader: String?

    public init(
        name: String,
        infoHash: String,
        downloadURL: URL,
        postedText: String?,
        sizeText: String?,
        seeds: Int?,
        peers: Int?,
        downloads: Int?,
        uploader: String?
    ) {
        self.name = name
        self.infoHash = infoHash
        self.downloadURL = downloadURL
        self.postedText = postedText
        self.sizeText = sizeText
        self.seeds = seeds
        self.peers = peers
        self.downloads = downloads
        self.uploader = uploader
    }

    /// `magnet:?xt=urn:btih:<infoHash>`. A hash other than hexadecimal digits (only possible through `init`) is
    /// percent-encoded.
    public var magnetURL: URL {
        let hash = infoHash.addingPercentEncoding(withAllowedCharacters: Self.hexDigits) ?? ""
        // Only hex digits and "%XX" escapes follow the fixed prefix, so the string is always a valid URL.
        return URL(string: "magnet:?xt=urn:btih:\(hash)")!
    }

    private static let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
}

// MARK: Favorites (`gallerypopups.php?act=addfav`)

/// One of the account's ten favorites folders.
public struct FavoriteFolder: Sendable, Hashable, Codable {
    /// The folder's number, 0…9 (`favcat`).
    public let index: Int
    /// The folder's name, as the account set it.
    public let name: String

    public init(index: Int, name: String) {
        self.index = index
        self.name = name
    }
}

/// The add-to-favorites popup of a gallery.
public struct FavoritesPopup: Sendable, Equatable, Codable {
    /// The folders, in page order.
    public var folders: [FavoriteFolder]
    /// The folder the popup has selected: the gallery's folder when it is a favorite, else the one the site picks.
    public var selectedIndex: Int?
    /// The account's note on the gallery; "" without one.
    public var note: String
    /// How many favorite notes the account has.
    public var noteSlotsUsed: Int?
    /// How many favorite notes the account can have.
    public var noteSlotsTotal: Int?
    /// The gallery is a favorite: the popup offers the "favdel" choice (remove from favorites).
    public var isFavorited: Bool

    public init(
        folders: [FavoriteFolder],
        selectedIndex: Int?,
        note: String,
        noteSlotsUsed: Int?,
        noteSlotsTotal: Int?,
        isFavorited: Bool
    ) {
        self.folders = folders
        self.selectedIndex = selectedIndex
        self.note = note
        self.noteSlotsUsed = noteSlotsUsed
        self.noteSlotsTotal = noteSlotsTotal
        self.isFavorited = isFavorited
    }
}
