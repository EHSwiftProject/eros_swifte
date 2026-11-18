import Foundation

/// A gallery category, as the site names it on list and detail pages.
public enum GalleryCategory: String, Sendable, Codable, CaseIterable {
    case misc, doujinshi, manga, artistCG, gameCG, imageSet, cosplay, asianPorn, nonH, western

    /// The category's name as the site shows it ("Artist CG", "Non-H", …).
    public var siteLabel: String {
        switch self {
        case .misc: "Misc"
        case .doujinshi: "Doujinshi"
        case .manga: "Manga"
        case .artistCG: "Artist CG"
        case .gameCG: "Game CG"
        case .imageSet: "Image Set"
        case .cosplay: "Cosplay"
        case .asianPorn: "Asian Porn"
        case .nonH: "Non-H"
        case .western: "Western"
        }
    }

    /// The category's bit in the search filter (`f_cats`), as the Flutter app's `EHConst.cats`.
    public var filterBit: Int {
        switch self {
        case .misc: 1
        case .doujinshi: 2
        case .manga: 4
        case .artistCG: 8
        case .gameCG: 16
        case .imageSet: 32
        case .cosplay: 64
        case .asianPorn: 128
        case .nonH: 256
        case .western: 512
        }
    }

    /// The category the site names `siteLabel`; case-insensitive, surrounding whitespace ignored. nil for any other
    /// text.
    public init?(siteLabel: String) {
        let label = siteLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let category = Self.allCases.first(where: { $0.siteLabel.lowercased() == label }) else { return nil }
        self = category
    }
}
