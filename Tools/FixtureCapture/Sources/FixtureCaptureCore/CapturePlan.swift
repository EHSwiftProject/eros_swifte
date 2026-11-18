import EHModels
import Foundation

/// Values earlier steps of a site's plan extracted for later ones. Only links and keys the site handed out are
/// kept, and only when they point back at the site being captured (the cover may be on an image host). It may hold
/// session-bound keys and the cover image, so printing, debug-printing or dumping it shows which values are set,
/// never the values.
public struct CaptureContext: Sendable {
    /// The first three galleries of the front page (step 1), for `gdata`.
    public var galleries: [GalleryRef] = []
    /// The front page's next page link (step 1).
    public var nextPageURL: URL?
    /// The action of the front page's file search form (step 1), when it is an `image_lookup.php` on the site's own
    /// or upload host over https.
    public var imageLookupURL: URL?
    /// The detail page's gid and token, from the URL that answered (step 20).
    public var gallery: GalleryRef?
    /// The first two image page links of the detail page (step 20).
    public var imagePageURLs: [URL] = []
    /// The archiver link's `or` key (step 20), when the link has one; the current site leaves it out.
    public var archiverKey: String?
    /// The cover image URL (step 20).
    public var coverURL: URL?
    /// The first image page's `showkey` (step 24).
    public var showkey: String?
    /// The first image page's reload token (step 24).
    public var reloadToken: String?
    /// The multi-page viewer's keys (step 27).
    public var mpvKeys: MPVKeys?
    /// The downloaded cover and its format (step 34), posted to the image lookup.
    public var cover: CoverImage?
    /// Where the image lookup redirects (step 35).
    public var lookupLocation: URL?
    /// What a step could not do as intended but worked around; explanations only, never a value.
    public var warnings: [String] = []

    public init() {}

    private var setFields: [String] {
        [
            ("galleries", !galleries.isEmpty), ("nextPageURL", nextPageURL != nil),
            ("imageLookupURL", imageLookupURL != nil), ("gallery", gallery != nil),
            ("imagePageURLs", !imagePageURLs.isEmpty), ("archiverKey", archiverKey != nil), ("coverURL", coverURL != nil),
            ("showkey", showkey != nil), ("reloadToken", reloadToken != nil), ("mpvKeys", mpvKeys != nil),
            ("cover", cover != nil), ("lookupLocation", lookupLocation != nil), ("warnings", !warnings.isEmpty),
        ].filter(\.1).map(\.0)
    }
}

extension CaptureContext: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "CaptureContext(set: \(setFields.joined(separator: ", ")))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["set": setFields], displayStyle: .struct) }
}

/// The request a step would send, or what it lacks. The reason names the missing value and where it comes from,
/// never a value.
enum StepResolution: Sendable {
    case ready(CaptureRequest)
    case missing(String)
}

/// What an ExHentai answer must look like for the capture to go on; ExHentai answers a session it no longer lets
/// in with an empty or non-HTML page.
enum ExBodyRule: Sendable {
    /// No requirement: JSON answers, the cover image, the image lookup redirect.
    case unchecked
    /// A body of some kind: pages that may legitimately be plain text (the not-found gallery).
    case nonEmpty
    /// An HTML page.
    case html
}

/// One request of a site's capture plan.
public struct CaptureStep: Sendable {
    /// Where the response goes, relative to the fixture root; nil = not saved (the cover download).
    public let fixturePath: String?
    public let site: EHSite
    /// Statuses that let the capture continue; anything else stops it.
    public let expectedStatus: Set<Int>
    /// The request, built from what earlier steps extracted; nil = something it depends on is missing, so the step
    /// is skipped.
    public let request: @Sendable (CaptureContext) -> CaptureRequest?
    /// Stores what later steps need from the response.
    public let extract: @Sendable (CaptureResponse, inout CaptureContext) -> Void
    /// The request's method, for the dry run.
    public let method: String
    /// The request's URL for the dry run: values from targets.json as they are, values extracted at run time as
    /// placeholders such as `{gid}`; `[…]` marks an optional part and `{name|fallback}` a value with its fallback.
    public let urlTemplate: String
    /// Whether a 4xx answer only skips this step (with a warning) instead of stopping the run. True for the image
    /// lookup and its result page only: they come last, need no login state, and the steps after them still catch a
    /// broken session.
    public let skipsOnClientError: Bool

    let resolve: @Sendable (CaptureContext) -> StepResolution
    /// What the answer must look like on ExHentai.
    let exBody: ExBodyRule

    /// - Parameter exBody: Defaults to `.html` for `.html` fixtures and `.unchecked` otherwise.
    init(
        _ fixturePath: String?,
        site: EHSite,
        expectedStatus: Set<Int> = [200],
        method: String = "GET",
        urlTemplate: String,
        exBody: ExBodyRule? = nil,
        skipsOnClientError: Bool = false,
        resolve: @escaping @Sendable (CaptureContext) -> StepResolution,
        extract: @escaping @Sendable (CaptureResponse, inout CaptureContext) -> Void = { _, _ in }
    ) {
        self.fixturePath = fixturePath
        self.site = site
        self.expectedStatus = expectedStatus
        self.method = method
        self.urlTemplate = urlTemplate
        self.skipsOnClientError = skipsOnClientError
        self.exBody = exBody ?? (fixturePath?.hasSuffix(".html") == true ? .html : .unchecked)
        self.resolve = resolve
        self.extract = extract
        request = { context in
            if case .ready(let request) = resolve(context) { request } else { nil }
        }
    }

    /// The fixture path, or a name for the unsaved cover download, for skipped steps and errors.
    var label: String { fixturePath ?? "\(site.rawValue) cover image (not saved)" }
}

/// The read-only capture plan: which pages and API answers become fixtures, in which order.
public enum CapturePlan {
    /// The `api.php` methods the plan calls; all of them only read.
    static let apiMethods: Set<String> = ["gdata", "showpage", "imagedispatch", "tagsuggest"]

    /// Separates the parts of the image lookup form.
    static let multipartBoundary = "----ErosFixtureCapture7d1f0b6a2c"

    /// The query parameters of the site's own "Disable Filters" link on a filtered list page (the same on both sites,
    /// seen in the M0 run), each with the value `on`.
    static let filterParameters = ["f_sft", "f_sfu", "f_sfl"]

    /// `filterParameters` as a query, `f_sft=on&f_sfu=on&f_sfl=on`, for the dry run's templates.
    static let filtersDisabledQuery = filterParameters.map { "\($0)=on" }.joined(separator: "&")

    /// Steps that may be skipped without failing the run: content warning (no target) and the two image lookup steps (4xx).
    public static func optionalFixturePaths(for site: EHSite) -> Set<String> {
        let s = site.rawValue
        return ["\(s)/gallery/content-warning.html", "\(s)/list/image-lookup-redirect.html", "\(s)/list/image-lookup.html"]
    }

    /// Every step for `site`, in capture order: 39 for EH (38 saved), 33 for EX (32 saved). Only GETs, `api.php`
    /// POSTs of `apiMethods` and the image lookup POST; no request sets anything on the site (see `isReadOnly`).
    ///
    /// The list pages that the account's filters thin out (the front page and its next page, seek, category, both
    /// searches, popular, tag and uploader) are requested with the filters disabled, as the site's own "Disable
    /// Filters" link does (`disablingFilters`): otherwise which galleries are missing would tell the account's
    /// hidden tags (user decision, 2026-11-05). These are query parameters of that one request; no site setting
    /// changes. The empty search, the favorites, watched, the toplists and the image lookup result showed no
    /// "Filtered" line in the M0 run and are requested as before; the hygiene check `filteredlist` refuses any page
    /// that shows one.
    public static func steps(for site: EHSite, targets: CaptureTargets.Site) -> [CaptureStep] {
        let s = site.rawValue
        let base = site.baseURL.absoluteString
        let front = "\(s)/list/front.html"
        let detail = "\(s)/gallery/detail.html"
        let imagePage = "\(s)/image/page.html"
        let mpv = "\(s)/mpv/mpv.html"
        let lookupRedirect = "\(s)/list/image-lookup-redirect.html"
        let api = "\(base)/api.php"

        func get(
            _ path: String?, _ url: String, template: String? = nil, expected: Set<Int> = [200], exBody: ExBodyRule? = nil
        ) -> CaptureStep {
            CaptureStep(path, site: site, expectedStatus: expected, urlTemplate: template ?? url, exBody: exBody) { _ in
                getting(URL(string: url), missing: "cannot build the URL from targets.json")
            }
        }

        func post(_ path: String, apiBody: @escaping @Sendable (CaptureContext) -> StepResolution) -> CaptureStep {
            CaptureStep(path, site: site, method: "POST", urlTemplate: api, resolve: apiBody)
        }

        /// A GET of a list page with the account's filters disabled.
        func list(_ path: String, _ url: String, template: String? = nil) -> CaptureStep {
            CaptureStep(path, site: site, urlTemplate: appendingQuery(template ?? url, filtersDisabledQuery)) { _ in
                getting(URL(string: url).map(disablingFilters), missing: "cannot build the URL from targets.json")
            }
        }

        let noGallery = StepResolution.missing("no gid and token in the URL of \(detail)")

        var steps: [CaptureStep] = [
            // 1
            CaptureStep(front, site: site, urlTemplate: "\(base)/?\(filtersDisabledQuery)",
                        resolve: { _ in .ready(CaptureRequest(url: disablingFilters(URL(string: "\(base)/")!))) },
                        extract: { response, context in
                            let html = response.text
                            context.galleries = Array(LinkExtractor.galleries(in: html).prefix(3))
                            context.nextPageURL = LinkExtractor.nextPageURL(in: html).flatMap { onSite($0, site) }
                            context.imageLookupURL = LinkExtractor.imageLookupURL(in: html)
                                .flatMap { isImageLookupURL($0, site: site) ? $0 : nil }
                        }),
            // 2: the link may carry the parameters already; `[…]` adds only those it lacks.
            CaptureStep("\(s)/list/front-next.html", site: site, urlTemplate: "{nextPage}[&\(filtersDisabledQuery)]") { context in
                getting(context.nextPageURL.map(disablingFilters), missing: "no next page link on \(site.host) in \(front)")
            },
            // 3–14
            list("\(s)/list/front-seek.html", "\(base)/?seek=2024-01-01"),
            list("\(s)/list/category.html", "\(base)/?f_cats=1021"),
            list("\(s)/list/search.html", "\(base)/?f_search=\(queryValue(targets.search))",
                 template: "\(base)/?f_search=\(targets.search)"),
            list("\(s)/list/search-advanced.html",
                 "\(base)/?f_search=\(queryValue(targets.search))&\(advancedSearch)",
                 template: "\(base)/?f_search=\(targets.search)&\(advancedSearch)"),
            get("\(s)/list/search-empty.html", "\(base)/?f_search=eros0fixture0nohit"),
            list("\(s)/list/popular.html", "\(base)/popular"),
            get("\(s)/list/watched.html", "\(base)/watched"),
            list("\(s)/list/tag.html", "\(base)/tag/\(pathSegment(targets.tag.replacingOccurrences(of: " ", with: "+")))",
                 template: "\(base)/tag/\(targets.tag.replacingOccurrences(of: " ", with: "+"))"),
            list("\(s)/list/uploader.html", "\(base)/uploader/\(pathSegment(targets.uploader))",
                 template: "\(base)/uploader/\(targets.uploader)"),
            get("\(s)/list/favorites.html", "\(base)/favorites.php"),
            get("\(s)/list/favorites-cat0.html", "\(base)/favorites.php?favcat=0"),
            get("\(s)/list/favorites-search.html", "\(base)/favorites.php?f_search=\(queryValue(targets.search))",
                template: "\(base)/favorites.php?f_search=\(targets.search)"),
        ]

        // 15–19
        if site == .eh {
            steps += [
                get("eh/list/toplist-yesterday.html", "https://e-hentai.org/toplist.php?tl=15"),
                get("eh/list/toplist-month.html", "https://e-hentai.org/toplist.php?tl=13"),
                get("eh/list/toplist-year.html", "https://e-hentai.org/toplist.php?tl=12"),
                get("eh/list/toplist-all.html", "https://e-hentai.org/toplist.php?tl=11"),
                get("eh/list/toplist-yesterday-p1.html", "https://e-hentai.org/toplist.php?tl=15&p=1"),
            ]
        }

        let gallery = targets.gallery
        let galleryPage1 = appendingQuery(gallery.absoluteString, "p=1")
        steps += [
            // 20
            CaptureStep(detail, site: site, urlTemplate: gallery.absoluteString,
                        resolve: { _ in .ready(CaptureRequest(url: gallery)) },
                        extract: { response, context in
                            let html = response.text
                            context.gallery = LinkExtractor.galleries(in: response.url.absoluteString).first
                            context.imagePageURLs = Array(
                                LinkExtractor.imagePageURLs(in: html).compactMap { onSite($0, site) }.prefix(2)
                            )
                            context.archiverKey = LinkExtractor.archiverKey(in: html)
                            context.coverURL = LinkExtractor.coverURL(in: html).flatMap(secure)
                        }),
            // 21
            get("\(s)/gallery/detail-p1.html", galleryPage1),
            // 22: the only request without nw=1, so the site shows its content warning.
            CaptureStep("\(s)/gallery/content-warning.html", site: site,
                        urlTemplate: targets.contentWarningGallery?.absoluteString ?? "{contentWarningGallery}") { _ in
                getting(targets.contentWarningGallery, includeNW: false, missing: "no contentWarningGallery in targets.json")
            },
            // 23
            // The site may answer an unknown gallery in plain text, so on ExHentai only an empty body stops here.
            get("\(s)/gallery/not-found.html", "\(base)/g/1/0000000000/", expected: [200, 404], exBody: .nonEmpty),
            // 24
            CaptureStep(imagePage, site: site, urlTemplate: "{imagePage1}",
                        resolve: { context in
                            getting(context.imagePageURLs.first, missing: "no image page links on \(site.host) in \(detail)")
                        },
                        extract: { response, context in
                            let html = response.text
                            context.showkey = LinkExtractor.showkey(in: html)
                            context.reloadToken = LinkExtractor.reloadToken(in: html)
                        }),
            // 25
            CaptureStep("\(s)/image/page-nl.html", site: site, urlTemplate: "{imagePage1}?nl={reloadToken}") { context in
                guard let page = context.imagePageURLs.first else {
                    return .missing("no image page links on \(site.host) in \(detail)")
                }
                guard let token = context.reloadToken else { return .missing("no reload token in \(imagePage)") }
                return getting(
                    URL(string: appendingQuery(page.absoluteString, "nl=\(queryValue(token))")),
                    missing: "cannot build the reload URL"
                )
            },
            // 26
            post("\(s)/api/showpage.json") { context in
                guard let gallery = context.gallery else { return noGallery }
                guard context.imagePageURLs.count >= 2, let key = imageKey(of: context.imagePageURLs[1]) else {
                    return .missing("no second image page link on \(site.host) in \(detail)")
                }
                guard let showkey = context.showkey else { return .missing("no showkey in \(imagePage)") }
                return apiRequest(api, #"{"method":"showpage","gid":\#(gallery.gid),"page":2,"imgkey":\#(jsonString(key)),"#
                    + #""showkey":\#(jsonString(showkey))}"#)
            },
            // 27
            CaptureStep(mpv, site: site, urlTemplate: "\(base)/mpv/{gid}/{token}/",
                        resolve: { context in
                            guard let gallery = context.gallery else { return noGallery }
                            return getting(
                                URL(string: "\(base)/mpv/\(gallery.gid)/\(pathSegment(gallery.token))/"),
                                missing: "cannot build the multi-page viewer URL"
                            )
                        },
                        extract: { response, context in
                            context.mpvKeys = LinkExtractor.mpvKeys(in: response.text)
                        }),
            // 28
            post("\(s)/api/imagedispatch.json") { context in
                guard let gallery = context.gallery else { return noGallery }
                guard let keys = context.mpvKeys else { return .missing("no mpvkey or image list in \(mpv)") }
                return apiRequest(api, #"{"method":"imagedispatch","gid":\#(gallery.gid),"page":1,"#
                    + #""imgkey":\#(jsonString(keys.firstImageKey)),"mpvkey":\#(jsonString(keys.mpvkey))}"#)
            },
            // 29–31: the popups' option pages only; nothing is posted back.
            galleryGet("\(s)/popup/favorites.html", site: site, base: base, page: "gallerypopups.php",
                       query: { "gid=\($0.gid)&t=\(queryValue($0.token))&act=addfav" },
                       template: "gid={gid}&t={token}&act=addfav", noGallery: noGallery),
            galleryGet("\(s)/popup/torrents.html", site: site, base: base, page: "gallerytorrents.php",
                       query: { "gid=\($0.gid)&t=\(queryValue($0.token))" },
                       template: "gid={gid}&t={token}", noGallery: noGallery),
            // `&or=` only when the detail page's archiver link has it; the current site leaves it out.
            CaptureStep("\(s)/popup/archiver.html", site: site,
                        urlTemplate: "\(base)/archiver.php?gid={gid}&token={token}[&or={or}]") { context in
                guard let gallery = context.gallery else { return noGallery }
                var url = "\(base)/archiver.php?gid=\(gallery.gid)&token=\(queryValue(gallery.token))"
                if let key = context.archiverKey { url += "&or=\(queryValue(key))" }
                return getting(URL(string: url), missing: "cannot build the archiver URL")
            },
            // 32
            post("\(s)/api/gdata.json") { context in
                guard !context.galleries.isEmpty else { return .missing("no gallery links in \(front)") }
                let list = context.galleries.map { "[\($0.gid),\(jsonString($0.token))]" }.joined(separator: ",")
                return apiRequest(api, #"{"method":"gdata","gidlist":[\#(list)]}"#)
            },
            // 33
            post("\(s)/api/tagsuggest.json") { _ in
                apiRequest(api, #"{"method":"tagsuggest","text":\#(jsonString(targets.tagSuggestText))}"#)
            },
            // 34: not saved; its body feeds the image lookup.
            CaptureStep(nil, site: site, urlTemplate: "{coverURL}",
                        resolve: { context in
                            getting(context.coverURL, missing: "no cover URL in \(detail)")
                        },
                        extract: { response, context in
                            guard !response.body.isEmpty else {
                                context.cover = nil
                                return
                            }
                            let (cover, problem) = CoverImage.from(
                                data: response.body, contentType: response.header("Content-Type")
                            )
                            context.cover = cover
                            let sent = "it was sent to the image lookup as \(cover.format.fileName) (\(cover.format.mimeType))"
                            switch problem {
                            case .unrecognized:
                                context.warnings.append("\(site.rawValue) cover image: neither its Content-Type nor its "
                                    + "file header is JPEG, PNG, GIF or WebP; \(sent)")
                            case .mismatch(let declared, let sniffed):
                                // Format names only, never the header value or the bytes.
                                context.warnings.append("\(site.rawValue) cover image: its Content-Type says "
                                    + "\(declared.rawValue) but its file header says \(sniffed.rawValue); \(sent)")
                            case nil:
                                break
                            }
                        }),
            // 35
            // The front page's file search form, else the site's current endpoint (`fallbackImageLookupURL`), posted
            // as a browser would from the front page. A 4xx skips this step and the next instead of stopping the run.
            CaptureStep(lookupRedirect, site: site, expectedStatus: [301, 302, 303], method: "POST",
                        urlTemplate: "{imageLookupURL|\(fallbackImageLookupURL(for: site).absoluteString)}",
                        exBody: .unchecked, skipsOnClientError: true,
                        resolve: { context in
                            guard let cover = context.cover else {
                                return .missing("no cover image from the cover download")
                            }
                            return .ready(CaptureRequest(
                                method: "POST",
                                url: context.imageLookupURL ?? fallbackImageLookupURL(for: site),
                                headers: [
                                    "Content-Type": "multipart/form-data; boundary=\(multipartBoundary)",
                                    "Referer": "\(base)/",
                                ],
                                body: imageLookupBody(cover: cover),
                                followRedirects: false
                            ))
                        },
                        extract: { response, context in
                            context.lookupLocation = response.header("Location")
                                .flatMap { URL(string: $0, relativeTo: response.url)?.absoluteURL }
                                .flatMap { onSite($0, site) }
                        }),
            // 36
            CaptureStep("\(s)/list/image-lookup.html", site: site, urlTemplate: "{location}", skipsOnClientError: true) { context in
                getting(context.lookupLocation, missing: "no Location on \(site.host) from \(lookupRedirect)")
            },
            // 37–38: GET only; the settings forms are never submitted.
            get("\(s)/account/uconfig.html", "\(base)/uconfig.php"),
            get("\(s)/account/mytags.html", "\(base)/mytags"),
        ]

        // 39: the forum profile page is not captured; it answered 403 to a non-browser client in the M0 run.
        if site == .eh {
            steps.append(get("eh/account/home.html", "https://e-hentai.org/home.php"))
        }
        return steps
    }

    private static let advancedSearch = "advsearch=1&f_sh=on&f_sto=on&f_sr=on&f_srdd=4&f_sp=on&f_spf=20&f_spt=200"

    /// A GET of `{base}/<page>?<query>` for the gallery from the detail page.
    private static func galleryGet(
        _ path: String,
        site: EHSite,
        base: String,
        page: String,
        query: @escaping @Sendable (GalleryRef) -> String,
        template: String,
        noGallery: StepResolution
    ) -> CaptureStep {
        CaptureStep(path, site: site, urlTemplate: "\(base)/\(page)?\(template)") { context in
            guard let gallery = context.gallery else { return noGallery }
            return getting(URL(string: "\(base)/\(page)?\(query(gallery))"), missing: "cannot build the popup URL")
        }
    }

    // MARK: Read-only rules

    /// Whether `request` only reads from `site`: a GET, a POST to the site's `api.php` whose JSON `method` is one of
    /// `gdata`, `showpage`, `imagedispatch` and `tagsuggest`, or a POST over https to an `image_lookup.php` on the
    /// site's own or upload host; and never anything that `mentionsInlineSet`. `Capturer` checks every request
    /// with this right before sending it, and `URLSessionCaptureTransport` every redirect it follows (which must
    /// be a GET).
    public static func isReadOnly(_ request: CaptureRequest, site: EHSite) -> Bool {
        readOnly(method: request.method, url: request.url, body: request.body, site: site)
    }

    /// True when the URL or the body mentions `inline_set`, the parameter that changes site settings, in any
    /// spelling PHP reads as it: percent-encoded (repeatedly), in any case, or with `.`, space, `+` or `[` in place
    /// of the underscore.
    public static func mentionsInlineSet(_ request: CaptureRequest) -> Bool {
        mentionsInlineSet(url: request.url, body: request.body)
    }

    /// `isReadOnly` for a request of `site`; with no site (a redirect), only a GET can pass.
    static func readOnly(method: String, url: URL, body: Data?, site: EHSite?) -> Bool {
        guard !mentionsInlineSet(url: url, body: body) else { return false }
        if method == "GET" { return true }
        guard method == "POST", let site else { return false }
        let host = url.host()?.lowercased()
        if host == site.host, url.path() == "/api.php" {
            guard let body,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let apiMethod = object["method"] as? String else { return false }
            return apiMethods.contains(apiMethod)
        }
        return isImageLookupURL(url, site: site)
    }

    static func mentionsInlineSet(url: URL, body: Data?) -> Bool {
        var texts = [url.absoluteString]
        if let body { texts.append(String(decoding: body, as: UTF8.self)) }
        return texts.contains { settingsNormalized($0).contains("inline_set") }
    }

    /// `text` percent-decoded until it stops changing (at most 3 rounds; malformed escapes stay as they are), then
    /// lowercased with `.`, space, `+` and `[` turned into `_`, as PHP does to parameter names.
    private static func settingsNormalized(_ text: String) -> String {
        var decoded = text
        for _ in 0..<3 {
            let next = percentDecoded(decoded)
            if next == decoded { break }
            decoded = next
        }
        var result = ""
        for character in decoded.lowercased() {
            result.append(".+ [".contains(character) ? "_" : character)
        }
        return result
    }

    private static func percentDecoded(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%"), index + 2 < bytes.count,
               let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                result.append(high << 4 | low)
                index += 3
            } else {
                result.append(bytes[index])
                index += 1
            }
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    /// Where the image lookup is posted when the front page has no file search form: on E-Hentai the upload host
    /// (`https://upld.e-hentai.org/image_lookup.php`), on ExHentai the site itself
    /// (`https://exhentai.org/upld/image_lookup.php`). The Flutter app's `https://upld.exhentai.org/image_lookup.php`
    /// answered 403 in the M0 run; JHenTai and PicImageSearch use these two.
    public static func fallbackImageLookupURL(for site: EHSite) -> URL {
        switch site {
        case .eh: URL(string: "https://upld.e-hentai.org/image_lookup.php")!
        case .ex: URL(string: "https://exhentai.org/upld/image_lookup.php")!
        }
    }

    /// True for https on `site`'s own host or the host of `fallbackImageLookupURL(for:)` (E-Hentai's upload host;
    /// ExHentai's is the site itself) with the last path component `image_lookup.php`.
    static func isImageLookupURL(_ url: URL, site: EHSite) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return false }
        let lookupHost = fallbackImageLookupURL(for: site).host()?.lowercased()
        return (host == site.host || host == lookupHost) && url.lastPathComponent == "image_lookup.php"
    }

    // MARK: Building requests

    /// A GET of `url`, or `.missing(reason)` when there is no URL.
    private static func getting(
        _ url: URL?,
        headers: [String: String] = [:],
        includeNW: Bool = true,
        missing reason: String
    ) -> StepResolution {
        guard let url else { return .missing(reason) }
        return .ready(CaptureRequest(url: url, headers: headers, includeNW: includeNW))
    }

    /// `url` with the account's filters disabled, as the site's own "Disable Filters" link has it: each of
    /// `filterParameters` exactly once, with the value `on`. A parameter the URL already has, in any spelling PHP
    /// reads as that name (`+` or percent escapes in it; `.`, space or `[` for the underscore), keeps its first place
    /// with the value `on` and loses its repeats; a missing one is appended. The rest of the URL stays as it is.
    static func disablingFilters(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.percentEncodedQueryItems ?? []
        for name in filterParameters {
            var kept = false
            items = items.compactMap { item in
                guard phpParameterName(item.name) == name else { return item }
                if kept { return nil }
                kept = true
                return URLQueryItem(name: name, value: "on")
            }
            if !kept { items.append(URLQueryItem(name: name, value: "on")) }
        }
        components.percentEncodedQueryItems = items
        return components.url ?? url
    }

    /// A query parameter name as PHP reads it: `+` and percent escapes decoded, then `.`, space and `[` turned into
    /// `_`. Case is kept, as PHP keeps it.
    private static func phpParameterName(_ encoded: String) -> String {
        let decoded = percentDecoded(encoded.replacingOccurrences(of: "+", with: " "))
        return String(decoded.map { ". [".contains($0) ? "_" : $0 })
    }

    /// A JSON POST of `body` to `api`.
    private static func apiRequest(_ api: String, _ body: String) -> StepResolution {
        guard let url = URL(string: api) else { return .missing("cannot build the API URL") }
        return .ready(CaptureRequest(
            method: "POST", url: url, headers: ["Content-Type": "application/json"], body: Data(body.utf8)
        ))
    }

    /// `url` when it is https on `site`'s own host, else nil: links taken from a page never send a request
    /// elsewhere.
    static func onSite(_ url: URL, _ site: EHSite) -> URL? {
        url.scheme?.lowercased() == "https" && url.host()?.lowercased() == site.host ? url : nil
    }

    /// `url` when it is https, else nil.
    private static func secure(_ url: URL) -> URL? {
        url.scheme?.lowercased() == "https" && url.host() != nil ? url : nil
    }

    /// The image key of an image page link, `/s/<key>/<gid>-<page>`.
    private static func imageKey(of page: URL) -> String? {
        let components = page.pathComponents
        return components.count >= 3 && components[1] == "s" ? components[2] : nil
    }

    /// `url` with `query` appended after `?`, or after `&` when it already has a query.
    private static func appendingQuery(_ url: String, _ query: String) -> String {
        url + (url.contains("?") ? "&" : "?") + query
    }

    /// Form encoding for a query value: unreserved characters and `:` stay, a space becomes `+`, every other UTF-8
    /// byte becomes `%XX`.
    static func queryValue(_ value: String) -> String {
        percentEncoded(value, keeping: ":").replacingOccurrences(of: "%20", with: "+")
    }

    /// Percent-encoding for one path segment: unreserved characters, `:` and `+` stay.
    static func pathSegment(_ value: String) -> String {
        percentEncoded(value, keeping: ":+")
    }

    private static func percentEncoded(_ value: String, keeping extra: String) -> String {
        let hex = Array("0123456789ABCDEF".unicodeScalars)
        let kept = Set(extra.utf8)
        var result = String.UnicodeScalarView()
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                result.append(Unicode.Scalar(byte))
            case _ where kept.contains(byte):
                result.append(Unicode.Scalar(byte))
            default:
                result.append("%")
                result.append(hex[Int(byte >> 4)])
                result.append(hex[Int(byte & 0x0F)])
            }
        }
        return String(result)
    }

    /// `value` as a JSON string literal, quotes included.
    private static func jsonString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        // Encoding a String cannot fail.
        return String(decoding: (try? encoder.encode(value)) ?? Data(#""""#.utf8), as: UTF8.self)
    }

    /// The image lookup form: the cover as `sfile` with the file name and MIME type of its format (`a.jpg` and
    /// `image/jpeg`, `a.png`, `a.gif`, `a.webp` and `image/webp`), `fs_similar=on`, `f_sfile=File Search`.
    private static func imageLookupBody(cover: CoverImage) -> Data {
        let boundary = multipartBoundary
        var body = Data()
        body.append(Data(
            ("--\(boundary)\r\nContent-Disposition: form-data; name=\"sfile\"; filename=\"\(cover.format.fileName)\"\r\n"
                + "Content-Type: \(cover.format.mimeType)\r\n\r\n").utf8
        ))
        body.append(cover.data)
        body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"fs_similar\"\r\n\r\non\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"f_sfile\"\r\n\r\nFile Search\r\n".utf8))
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }
}
