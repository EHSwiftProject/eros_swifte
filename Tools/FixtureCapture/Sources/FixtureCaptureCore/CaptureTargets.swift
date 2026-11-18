import EHModels
import Foundation

/// What to capture on each site, read from `Tools/FixtureCapture/targets.json`. It names public pages and
/// search terms only, never personal data, so it is checked in.
public struct CaptureTargets: Codable, Sendable {
    public struct Site: Codable, Sendable {
        /// A gallery detail page, `https://<host>/g/<gid>/<token>/`.
        public var gallery: URL
        /// A gallery behind the content warning; null skips that fixture.
        public var contentWarningGallery: URL?
        /// `f_search` for the search and favorites search lists.
        public var search: String
        /// Tag for `/tag/…`; spaces become `+`.
        public var tag: String
        /// Uploader for `/uploader/…`.
        public var uploader: String
        /// Text sent to the `tagsuggest` API.
        public var tagSuggestText: String

        public init(
            gallery: URL,
            contentWarningGallery: URL?,
            search: String,
            tag: String,
            uploader: String,
            tagSuggestText: String
        ) {
            self.gallery = gallery
            self.contentWarningGallery = contentWarningGallery
            self.search = search
            self.tag = tag
            self.uploader = uploader
            self.tagSuggestText = tagSuggestText
        }
    }

    public var eh: Site
    public var ex: Site

    public init(eh: Site, ex: Site) {
        self.eh = eh
        self.ex = ex
    }

    public subscript(site: EHSite) -> Site {
        switch site {
        case .eh: eh
        case .ex: ex
        }
    }
}
