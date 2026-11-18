import EHModels
import FixtureCaptureCore
import Foundation
import Testing

/// The fixture paths of the EH plan, in order (39 steps; the cover download is not saved).
private let ehFixturePaths = [
    "eh/list/front.html", "eh/list/front-next.html", "eh/list/front-seek.html", "eh/list/category.html",
    "eh/list/search.html", "eh/list/search-advanced.html", "eh/list/search-empty.html", "eh/list/popular.html",
    "eh/list/watched.html", "eh/list/tag.html", "eh/list/uploader.html", "eh/list/favorites.html",
    "eh/list/favorites-cat0.html", "eh/list/favorites-search.html",
    "eh/list/toplist-yesterday.html", "eh/list/toplist-month.html", "eh/list/toplist-year.html",
    "eh/list/toplist-all.html", "eh/list/toplist-yesterday-p1.html",
    "eh/gallery/detail.html", "eh/gallery/detail-p1.html", "eh/gallery/content-warning.html",
    "eh/gallery/not-found.html", "eh/image/page.html", "eh/image/page-nl.html", "eh/api/showpage.json",
    "eh/mpv/mpv.html", "eh/api/imagedispatch.json", "eh/popup/favorites.html", "eh/popup/torrents.html",
    "eh/popup/archiver.html", "eh/api/gdata.json", "eh/api/tagsuggest.json",
    "eh/list/image-lookup-redirect.html", "eh/list/image-lookup.html", "eh/account/uconfig.html",
    "eh/account/mytags.html", "eh/account/home.html",
]

private let ehOnlyFixturePaths: Set<String> = [
    "eh/list/toplist-yesterday.html", "eh/list/toplist-month.html", "eh/list/toplist-year.html",
    "eh/list/toplist-all.html", "eh/list/toplist-yesterday-p1.html", "eh/account/home.html",
]

private let allowedAPIMethods: Set<String> = ["gdata", "showpage", "imagedispatch", "tagsuggest"]

/// The list pages that said "Filtered N galleries from this page" in the M0 run, on both sites: the ones requested
/// with the account's filters disabled.
private func unfilteredListPaths(_ site: EHSite) -> Set<String> {
    Set(["front", "front-next", "front-seek", "category", "search", "search-advanced", "popular", "tag", "uploader"]
        .map { "\(site.rawValue)/list/\($0).html" })
}

/// The site's Disable Filters parameters.
private let filterParameterNames = ["f_sft", "f_sfu", "f_sfl"]

/// The values of each query parameter of `url`, by name as sent, in order.
private func queryValues(_ url: URL) -> [String: [String]] {
    var values: [String: [String]] = [:]
    for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems ?? [] {
        values[item.name, default: []].append(item.value ?? "")
    }
    return values
}

/// Every value a step can depend on, as earlier steps of `site` would extract it.
private func fullContext(for site: EHSite) -> CaptureContext {
    var context = CaptureContext()
    context.galleries = [
        GalleryRef(gid: 101, token: "0a0a0a0a0a"), GalleryRef(gid: 102, token: "0b0b0b0b0b"),
        GalleryRef(gid: 103, token: "0c0c0c0c0c"),
    ]
    context.nextPageURL = URL(string: "https://\(site.host)/?next=103")
    context.imageLookupURL = URL(string: CannedSite.lookupAction(host: site.host))
    context.gallery = GalleryRef(gid: 123, token: "abcdef0123")
    context.imagePageURLs = [
        URL(string: "https://\(site.host)/s/0a1b2c3d4e/123-1")!, URL(string: "https://\(site.host)/s/f0e1d2c3b4/123-2")!,
    ]
    context.archiverKey = "474357--a8c5d0"
    context.coverURL = URL(string: "https://ehgt.org/ab/cd/x.jpg")
    context.showkey = "abc123def4"
    context.reloadToken = "12345-430636"
    context.mpvKeys = MPVKeys(mpvkey: "k1a2b3", firstImageKey: "fedcba9876")
    context.cover = CoverImage(data: Data([0xFF, 0xD8, 0xFF, 0xE0]), format: .jpeg)
    context.lookupLocation = URL(string: "https://\(site.host)/?f_shash=0123456789abcdef")
    return context
}

private func steps(_ site: EHSite, contentWarning: Bool = true) -> [CaptureStep] {
    CapturePlan.steps(for: site, targets: CaptureFakes.site(site, contentWarning: contentWarning))
}

/// `template` with each optional part `[…]` kept (brackets dropped) when every placeholder in it has a value, and
/// removed otherwise; each `{name|fallback}` replaced by the value of `{name}`, or else by its fallback; then every
/// placeholder replaced by its value.
private func expand(_ template: String, _ values: [String: String]) -> String {
    var result = ""
    let withFallbacks = template.replacing(/\{([A-Za-z0-9]+)\|([^}]*)\}/) { match in
        values["{\(match.output.1)}"] ?? String(match.output.2)
    }
    var rest = Substring(withFallbacks)
    while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
        result += rest[..<open]
        let part = String(rest[rest.index(after: open)..<close])
        let placeholders = part.matches(of: /\{[A-Za-z0-9]+\}/).map { String($0.output) }
        if placeholders.allSatisfy({ values[$0] != nil }) { result += part }
        rest = rest[rest.index(after: close)...]
    }
    result += rest
    for (placeholder, value) in values { result = result.replacingOccurrences(of: placeholder, with: value) }
    return result
}

/// The image lookup body that step 35 posts after step 34 downloaded `cover` (as text, and as bytes), and the
/// warnings step 34 left.
private func lookupBody(
    afterCover cover: CaptureResponse, site: EHSite = .eh
) throws -> (body: String, bytes: Data, warnings: [String]) {
    let plan = steps(site)
    let download = try #require(plan.first { $0.fixturePath == nil })
    let lookup = try #require(plan.first { $0.fixturePath == "\(site.rawValue)/list/image-lookup-redirect.html" })
    var context = fullContext(for: site)
    context.cover = nil
    download.extract(cover, &context)
    let bytes = try #require(lookup.request(context)?.body)
    return (String(decoding: bytes, as: UTF8.self), bytes, context.warnings)
}

private func image(_ contentType: String?, _ bytes: [UInt8]) -> CaptureResponse {
    CaptureResponse(
        status: 200, headers: contentType.map { ["Content-Type": $0] } ?? [:], body: Data(bytes),
        url: URL(string: "https://ehgt.org/ab/cd/x.webp")!
    )
}

private let jpegHeader: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]
private let pngHeader: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00]
private let gifHeader: [UInt8] = Array("GIF89a".utf8) + [0x01, 0x00]
private let webpHeader: [UInt8] = Array("RIFF".utf8) + [0x24, 0x00, 0x00, 0x00] + Array("WEBPVP8 ".utf8)

/// The `method` of a JSON API body, or nil.
private func apiMethod(_ body: Data?) -> String? {
    guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
    return object["method"] as? String
}

@Suite struct CapturePlanTests {
    @Test func ehPlanFixturePaths() {
        let plan = steps(.eh)
        #expect(plan.count == 39)
        #expect(plan.compactMap(\.fixturePath) == ehFixturePaths)
        #expect(plan.allSatisfy { $0.site == .eh })
        // The cover download sits between tagsuggest and the image lookup.
        #expect(plan.firstIndex { $0.fixturePath == nil } == 33)
    }

    @Test func ehPlanHasNoForumSteps() {
        // The forum profile answered 403 to a non-browser client in the M0 run, so no step targets the forum host.
        let context = fullContext(for: .eh)
        let hosts = steps(.eh).compactMap { $0.request(context)?.url.host()?.lowercased() }
        #expect(!hosts.isEmpty)
        #expect(!hosts.contains("forums.e-hentai.org"))
        #expect(steps(.eh).allSatisfy { !$0.urlTemplate.contains("forums.e-hentai.org") })
        #expect(steps(.eh).allSatisfy { !($0.fixturePath ?? "").contains("forum") })
    }

    @Test func exPlanOmitsEHOnlyFixtures() {
        let plan = steps(.ex)
        let paths = plan.compactMap(\.fixturePath)
        #expect(plan.count == 33)
        #expect(paths.count == 32)
        #expect(paths == ehFixturePaths.filter { !ehOnlyFixturePaths.contains($0) }.map { "ex/" + $0.dropFirst(3) })
        #expect(!paths.contains { $0.contains("toplist-") || $0 == "ex/account/home.html" })
        #expect(plan.allSatisfy { $0.site == .ex })
    }

    @Test func everyStepHasARequestWithFullContext() {
        for site in EHSite.allCases {
            let context = fullContext(for: site)
            let missing = steps(site).filter { $0.request(context) == nil }.map { $0.fixturePath ?? "cover" }
            #expect(missing.isEmpty, "steps without a request: \(missing)")
        }
    }

    @Test func noRequestContainsInlineSet() {
        for site in EHSite.allCases {
            let context = fullContext(for: site)
            for step in steps(site) {
                guard let request = step.request(context) else { continue }
                let text = request.url.absoluteString + String(decoding: request.body ?? Data(), as: UTF8.self)
                let clean = text.range(of: "inline_set", options: .caseInsensitive) == nil
                    && !CapturePlan.mentionsInlineSet(request)
                #expect(clean, "\(step.fixturePath ?? "cover") sends inline_set")
            }
        }
    }

    @Test func planIsReadOnly() {
        for site in EHSite.allCases {
            let context = fullContext(for: site)
            var posts: [String] = []
            for step in steps(site) {
                guard let request = step.request(context), request.method != "GET" else { continue }
                let label = step.fixturePath ?? "cover"
                posts.append(label)
                let isAPI = request.method == "POST" && request.url.host() == site.host && request.url.path() == "/api.php"
                    && apiMethod(request.body).map(allowedAPIMethods.contains) == true
                    && request.headers["Content-Type"] == "application/json"
                let isLookup = request.method == "POST" && request.url.scheme == "https"
                    && [site.host, CapturePlan.fallbackImageLookupURL(for: site).host()!].contains(request.url.host() ?? "")
                    && request.url.lastPathComponent == "image_lookup.php"
                #expect(isAPI || isLookup, "\(label) is not an allowed read-only request")
                #expect(CapturePlan.isReadOnly(request, site: site), "\(label) fails the runtime read-only check")
            }
            let s = site.rawValue
            #expect(posts == [
                "\(s)/api/showpage.json", "\(s)/api/imagedispatch.json", "\(s)/api/gdata.json", "\(s)/api/tagsuggest.json",
                "\(s)/list/image-lookup-redirect.html",
            ])
        }
    }

    @Test func apiBodiesMatchThePlan() {
        let context = fullContext(for: .eh)
        let bodies = Dictionary(uniqueKeysWithValues: steps(.eh).compactMap { step -> (String, String)? in
            guard let path = step.fixturePath, path.hasPrefix("eh/api/"), let body = step.request(context)?.body else { return nil }
            return (path, String(decoding: body, as: UTF8.self))
        })
        #expect(bodies["eh/api/showpage.json"] == #"{"method":"showpage","gid":123,"page":2,"imgkey":"f0e1d2c3b4","showkey":"abc123def4"}"#)
        #expect(bodies["eh/api/imagedispatch.json"] == #"{"method":"imagedispatch","gid":123,"page":1,"imgkey":"fedcba9876","mpvkey":"k1a2b3"}"#)
        #expect(bodies["eh/api/gdata.json"] == #"{"method":"gdata","gidlist":[[101,"0a0a0a0a0a"],[102,"0b0b0b0b0b"],[103,"0c0c0c0c0c"]]}"#)
        #expect(bodies["eh/api/tagsuggest.json"] == #"{"method":"tagsuggest","text":"chin"}"#)
    }

    @Test func imageLookupDoesNotFollowRedirects() throws {
        let context = fullContext(for: .eh)
        let lookup = try #require(steps(.eh).first { $0.fixturePath == "eh/list/image-lookup-redirect.html" })
        let request = try #require(lookup.request(context))
        #expect(!request.followRedirects)
        #expect(lookup.expectedStatus == [301, 302, 303])
        #expect(request.url == context.imageLookupURL)
        let contentType = request.headers["Content-Type"] ?? ""
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        #expect(body.contains(#"name="sfile"; filename="a.jpg""#))
        #expect(body.contains("Content-Type: image/jpeg"))
        #expect(body.contains("name=\"fs_similar\"\r\n\r\non\r\n"))
        #expect(body.contains("name=\"f_sfile\"\r\n\r\nFile Search\r\n"))
        // Every other step follows redirects.
        #expect(steps(.eh).filter { $0.request(context)?.followRedirects == false }.count == 1)
    }

    @Test func expectedStatusesAre200ExceptNotFoundAndLookup() {
        for site in EHSite.allCases {
            let others = steps(site).filter { step in
                guard let path = step.fixturePath else { return step.expectedStatus != [200] }
                switch path {
                case "\(site.rawValue)/gallery/not-found.html": return step.expectedStatus != [200, 404]
                case "\(site.rawValue)/list/image-lookup-redirect.html": return step.expectedStatus != [301, 302, 303]
                default: return step.expectedStatus != [200]
                }
            }
            #expect(others.isEmpty)
        }
    }

    @Test func imageLookupFallsBackToTheSitesCurrentEndpoint() throws {
        // E-Hentai: the upload host. ExHentai: its own /upld/ path; the Flutter app's upld.exhentai.org answered 403.
        let fallbacks: [EHSite: String] = [
            .eh: "https://upld.e-hentai.org/image_lookup.php", .ex: "https://exhentai.org/upld/image_lookup.php",
        ]
        for site in EHSite.allCases {
            var context = fullContext(for: site)
            context.imageLookupURL = nil
            let lookup = try #require(steps(site).first { $0.fixturePath == "\(site.rawValue)/list/image-lookup-redirect.html" })
            let request = try #require(lookup.request(context))
            let fallback = try #require(fallbacks[site])
            #expect(request.url == URL(string: fallback))
            #expect(lookup.urlTemplate == "{imageLookupURL|\(fallback)}")
            #expect(expand(lookup.urlTemplate, [:]) == fallback)
            #expect(CapturePlan.isReadOnly(request, site: site), "\(fallback) fails the read-only check")
        }
    }

    @Test func imageLookupIsPostedFromTheFrontPage() throws {
        // As a browser posts it from the front page, with or without the page's own form.
        for site in EHSite.allCases {
            var context = fullContext(for: site)
            let lookup = try #require(steps(site).first { $0.fixturePath == "\(site.rawValue)/list/image-lookup-redirect.html" })
            for formAction in [context.imageLookupURL, nil] {
                context.imageLookupURL = formAction
                let referer = lookup.request(context)?.headers["Referer"]
                #expect(referer == "https://\(site.host)/")
            }
        }
        // No other step sends a Referer.
        let others = steps(.eh).filter { $0.fixturePath != "eh/list/image-lookup-redirect.html" }
            .compactMap { $0.request(fullContext(for: .eh)) }.filter { $0.headers["Referer"] != nil }
        #expect(others.isEmpty)
    }

    @Test func onlyTheImageLookupStepsSkipOnClientErrors() {
        for site in EHSite.allCases {
            let skipping = steps(site).filter(\.skipsOnClientError).map { $0.fixturePath ?? "cover" }
            #expect(skipping == ["\(site.rawValue)/list/image-lookup-redirect.html", "\(site.rawValue)/list/image-lookup.html"])
        }
    }

    @Test func inlineSetSpellingsAreRefused() throws {
        let spellings = [
            "inline_set=dm_t", "inline%5Fset=dm_t", "inline%5fset=dm_t", "inline%255Fset=dm_t", "inline.set=dm_t",
            "INLINE_SET=x", "Inline_Set=x", "inline[set=x", "inline%5Bset=x", "inline+set=x", "inline%20set=x",
            "f_search=x&inline%2Eset=dm_t",
        ]
        for spelling in spellings {
            let get = CaptureRequest(url: try #require(URL(string: "https://e-hentai.org/?\(spelling)")))
            let refused = CapturePlan.mentionsInlineSet(get) && !CapturePlan.isReadOnly(get, site: .eh)
            #expect(refused, "GET ?\(spelling) passes the read-only check")
            let post = CaptureRequest(
                method: "POST", url: URL(string: "https://upld.e-hentai.org/image_lookup.php")!,
                body: Data("--b\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\n\(spelling)\r\n".utf8)
            )
            let refusedBody = CapturePlan.mentionsInlineSet(post) && !CapturePlan.isReadOnly(post, site: .eh)
            #expect(refusedBody, "a body with \(spelling) passes the read-only check")
        }
        // Neighbouring words are fine; anything containing the normalized name (even "inline settings") is not.
        for clean in ["f_search=inline", "f_search=online_set", "f_search=inline+style"] {
            let request = CaptureRequest(url: try #require(URL(string: "https://e-hentai.org/?\(clean)")))
            #expect(!CapturePlan.mentionsInlineSet(request), "?\(clean) counts as inline_set")
            #expect(CapturePlan.isReadOnly(request, site: .eh))
        }
    }

    @Test func isReadOnlyAllowsOnlyListedPosts() throws {
        func api(_ method: String, host: String = "e-hentai.org", path: String = "/api.php") -> CaptureRequest {
            CaptureRequest(
                method: "POST", url: URL(string: "https://\(host)\(path)")!, headers: ["Content-Type": "application/json"],
                body: Data(#"{"method":"\#(method)","gid":1}"#.utf8)
            )
        }
        for method in ["gdata", "showpage", "imagedispatch", "tagsuggest"] {
            #expect(CapturePlan.isReadOnly(api(method), site: .eh), "\(method) is refused")
        }
        // Writing API methods, another site's API, other endpoints.
        for request in [
            api("rategallery"), api("votecomment"), api("taggallery"), api("gdata", host: "exhentai.org"),
            api("gdata", path: "/uconfig.php"), api("gdata", path: "/mytags"), api("gdata", path: "/gallerypopups.php"),
            api("gdata", path: "/archiver.php"),
            CaptureRequest(method: "POST", url: URL(string: "https://e-hentai.org/api.php")!, body: Data("not json".utf8)),
            CaptureRequest(method: "POST", url: URL(string: "https://e-hentai.org/api.php")!),
        ] {
            #expect(!CapturePlan.isReadOnly(request, site: .eh), "\(request.url.path()) is allowed")
        }
        // The image lookup: https, on the site's own or upload host, ending in image_lookup.php.
        for allowed in [
            "https://upld.e-hentai.org/image_lookup.php", "https://e-hentai.org/upld/image_lookup.php",
        ] {
            let request = CaptureRequest(method: "POST", url: URL(string: allowed)!, body: Data("x".utf8))
            #expect(CapturePlan.isReadOnly(request, site: .eh), "\(allowed) is refused")
        }
        for refused in [
            "http://upld.e-hentai.org/image_lookup.php", "https://upld.exhentai.org/image_lookup.php",
            "https://upld.example.org/image_lookup.php", "https://upld.e-hentai.org/image_lookup.php.evil",
            "https://upld.e-hentai.org/upload.php",
        ] {
            let request = CaptureRequest(method: "POST", url: URL(string: refused)!, body: Data("x".utf8))
            #expect(!CapturePlan.isReadOnly(request, site: .eh), "\(refused) is allowed")
        }
        #expect(CapturePlan.isReadOnly(api("gdata", host: "exhentai.org"), site: .ex))
        // Methods other than GET and POST never pass.
        for method in ["PUT", "DELETE", "PATCH", "get"] {
            let request = CaptureRequest(method: method, url: URL(string: "https://e-hentai.org/")!)
            #expect(!CapturePlan.isReadOnly(request, site: .eh), "\(method) is allowed")
        }
        #expect(CapturePlan.isReadOnly(CaptureRequest(url: URL(string: "https://ehgt.org/x.jpg")!), site: .eh))
    }

    @Test func onlyContentWarningOmitsNW() {
        for site in EHSite.allCases {
            let context = fullContext(for: site)
            let withoutNW = steps(site).filter { $0.request(context)?.includeNW == false }.map(\.fixturePath)
            #expect(withoutNW == ["\(site.rawValue)/gallery/content-warning.html"])
        }
    }

    @Test func missingContentWarningTargetYieldsNilRequest() throws {
        let context = fullContext(for: .eh)
        let step = try #require(steps(.eh, contentWarning: false).first { $0.fixturePath == "eh/gallery/content-warning.html" })
        #expect(step.request(context) == nil)
    }

    @Test func dependentStepsNeedTheirInputs() {
        let empty = CaptureContext()
        let needing = steps(.eh).filter { $0.request(empty) == nil }.map { $0.fixturePath ?? "cover" }
        #expect(needing == [
            "eh/list/front-next.html", "eh/image/page.html", "eh/image/page-nl.html", "eh/api/showpage.json",
            "eh/mpv/mpv.html", "eh/api/imagedispatch.json", "eh/popup/favorites.html", "eh/popup/torrents.html",
            "eh/popup/archiver.html", "eh/api/gdata.json", "cover", "eh/list/image-lookup-redirect.html",
            "eh/list/image-lookup.html",
        ])
    }

    /// The dry-run template of each step, with its placeholders filled from the context, is the URL it requests.
    @Test func templatesMatchRequests() {
        for site in EHSite.allCases {
            let context = fullContext(for: site)
            let target = CaptureFakes.site(site, contentWarning: true)
            let values: [String: String] = [
                "{nextPage}": context.nextPageURL!.absoluteString,
                "{gid}": "123", "{token}": "abcdef0123",
                "{imagePage1}": context.imagePageURLs[0].absoluteString,
                "{reloadToken}": context.reloadToken!,
                "{or}": context.archiverKey!,
                "{coverURL}": context.coverURL!.absoluteString,
                "{location}": context.lookupLocation!.absoluteString,
                "{imageLookupURL}": context.imageLookupURL!.absoluteString,
                "{contentWarningGallery}": target.contentWarningGallery!.absoluteString,
            ]
            for step in steps(site) {
                guard let request = step.request(context) else { continue }
                let expected = expand(step.urlTemplate, values)
                let matches = request.url.absoluteString.removingPercentEncoding == expected && request.method == step.method
                #expect(matches, "\(step.fixturePath ?? "cover"): template does not match the request")
            }
        }
    }

    // MARK: Archiver

    @Test func archiverTemplateMarksTheOrKeyOptional() throws {
        let archiver = try #require(steps(.eh).first { $0.fixturePath == "eh/popup/archiver.html" })
        #expect(archiver.urlTemplate == "https://e-hentai.org/archiver.php?gid={gid}&token={token}[&or={or}]")
    }

    @Test func archiverWithOrKeySendsIt() throws {
        for site in EHSite.allCases {
            let archiver = try #require(steps(site).first { $0.fixturePath == "\(site.rawValue)/popup/archiver.html" })
            let url = archiver.request(fullContext(for: site))?.url
            #expect(url == URL(string: "https://\(site.host)/archiver.php?gid=123&token=abcdef0123&or=474357--a8c5d0"))
        }
    }

    @Test func archiverWithoutOrKeyUsesGidAndTokenOnly() throws {
        for site in EHSite.allCases {
            var context = fullContext(for: site)
            context.archiverKey = nil
            let archiver = try #require(steps(site).first { $0.fixturePath == "\(site.rawValue)/popup/archiver.html" })
            let request = try #require(archiver.request(context), "the archiver step needs no or key")
            #expect(request.url == URL(string: "https://\(site.host)/archiver.php?gid=123&token=abcdef0123"))
            #expect(request.method == "GET")
            #expect(CapturePlan.isReadOnly(request, site: site))
            // The template without its optional part is the request.
            let expected = expand(archiver.urlTemplate, ["{gid}": "123", "{token}": "abcdef0123"])
            #expect(request.url.absoluteString == expected)
        }
    }

    // MARK: Image lookup format

    @Test(arguments: [
        ("image/jpeg", "a.jpg", "image/jpeg"), ("image/png", "a.png", "image/png"), ("image/gif", "a.gif", "image/gif"),
        ("image/webp", "a.webp", "image/webp"), ("IMAGE/WebP; charset=binary", "a.webp", "image/webp"),
        ("image/jpg", "a.jpg", "image/jpeg"), ("image/pjpeg", "a.jpg", "image/jpeg"),
    ])
    func imageLookupUsesTheCoverContentType(contentType: String, fileName: String, mimeType: String) throws {
        // The bytes show no known header, so only the Content-Type can decide.
        let (body, _, warnings) = try lookupBody(afterCover: image(contentType, [0x00, 0x01, 0x02, 0x03]))
        #expect(body.contains(#"name="sfile"; filename="\#(fileName)""#))
        #expect(body.contains("Content-Type: \(mimeType)\r\n\r\n"))
        #expect(warnings.isEmpty)
    }

    @Test func contentTypeWinsOverTheFileHeader() throws {
        let (body, _, warnings) = try lookupBody(afterCover: image("image/png", webpHeader))
        #expect(body.contains(#"filename="a.png""#))
        #expect(body.contains("Content-Type: image/png\r\n"))
        // The two disagree: one warning naming both formats.
        #expect(warnings == [
            "eh cover image: its Content-Type says png but its file header says webp; "
                + "it was sent to the image lookup as a.png (image/png)",
        ])
    }

    @Test func mismatchWarningNamesFormatsOnly() throws {
        let (body, _, warnings) = try lookupBody(afterCover: image("image/JPEG; zqfake=param", webpHeader))
        #expect(body.contains(#"filename="a.jpg""#))
        #expect(warnings.count == 1)
        let named = warnings.allSatisfy { $0.contains("says jpeg") && $0.contains("says webp") }
        #expect(named)
        let leaks = warnings.contains { $0.contains("zqfake") || $0.contains("RIFF") || $0.contains("JPEG;") }
        #expect(!leaks, "the warning repeats the Content-Type or the bytes")
        // Agreeing sources warn about nothing.
        let (_, _, agreeing) = try lookupBody(afterCover: image("image/webp", webpHeader))
        #expect(agreeing.isEmpty)
    }

    @Test(arguments: [
        (nil as String?, "jpeg"), ("application/octet-stream", "png"), ("text/plain", "gif"), ("", "webp"),
    ])
    func imageLookupFallsBackToTheFileHeader(contentType: String?, format: String) throws {
        let header = try #require(["jpeg": jpegHeader, "png": pngHeader, "gif": gifHeader, "webp": webpHeader][format])
        let expected = try #require(CoverImageFormat(rawValue: format))
        let (body, bytes, warnings) = try lookupBody(afterCover: image(contentType, header))
        #expect(body.contains(#"filename="\#(expected.fileName)""#))
        #expect(body.contains("Content-Type: \(expected.mimeType)\r\n"))
        #expect(warnings.isEmpty)
        // The cover itself is posted unchanged.
        #expect(bytes.range(of: Data(header)) != nil)
    }

    @Test func unrecognizedCoverIsSentAsJPEGWithAWarning() throws {
        let (body, _, warnings) = try lookupBody(afterCover: image("application/x-zqfake-type", [0x00, 0x01, 0x02, 0x03]))
        #expect(body.contains(#"filename="a.jpg""#))
        #expect(body.contains("Content-Type: image/jpeg\r\n"))
        #expect(warnings.count == 1)
        // The warning names the site and the fallback, never the type or the bytes it got.
        let names = warnings.allSatisfy { $0.hasPrefix("eh cover image:") && $0.contains("a.jpg (image/jpeg)") }
        #expect(names)
        let leaks = warnings.contains { $0.contains("zqfake") }
        #expect(!leaks, "the warning repeats the Content-Type")
    }

    @Test func emptyCoverSkipsTheLookup() throws {
        let plan = steps(.eh)
        let download = try #require(plan.first { $0.fixturePath == nil })
        let lookup = try #require(plan.first { $0.fixturePath == "eh/list/image-lookup-redirect.html" })
        var context = fullContext(for: .eh)
        download.extract(image("image/webp", []), &context)
        #expect(context.cover == nil)
        #expect(lookup.request(context) == nil)
        #expect(context.warnings.isEmpty)
    }

    @Test func templatesUseTargetsAsIsAndPlaceholdersForExtractedValues() {
        let lines = steps(.eh, contentWarning: false).map { "\($0.method) \($0.urlTemplate)" }
        #expect(lines.contains("GET https://e-hentai.org/?f_sft=on&f_sfu=on&f_sfl=on"))
        #expect(lines.contains("GET https://e-hentai.org/?f_search=language:chinese&f_sft=on&f_sfu=on&f_sfl=on"))
        #expect(lines.contains("GET https://e-hentai.org/tag/language:chinese?f_sft=on&f_sfu=on&f_sfl=on"))
        #expect(lines.contains("GET {nextPage}[&f_sft=on&f_sfu=on&f_sfl=on]"))
        #expect(lines.contains("GET https://e-hentai.org/?f_search=eros0fixture0nohit"))
        #expect(lines.contains("GET https://e-hentai.org/g/123/abcdef0123/?p=1"))
        #expect(lines.contains("GET https://e-hentai.org/mpv/{gid}/{token}/"))
        #expect(!lines.contains { $0.contains("forums.e-hentai.org") })
        #expect(lines.contains("POST {imageLookupURL|https://upld.e-hentai.org/image_lookup.php}"))
    }

    // MARK: Filters disabled

    @Test func listStepsDisableFiltersExactlyOnce() {
        for site in EHSite.allCases {
            let context = fullContext(for: site)
            var disabling: Set<String> = []
            for step in steps(site) {
                guard let request = step.request(context) else { continue }
                let values = queryValues(request.url)
                let label = step.fixturePath ?? "cover"
                guard request.url.absoluteString.contains("f_sf") else { continue }
                disabling.insert(label)
                let once = filterParameterNames.allSatisfy { values[$0] == ["on"] }
                #expect(once, "\(label): each Disable Filters parameter must be sent once, as on")
            }
            #expect(disabling == unfilteredListPaths(site))
        }
    }

    @Test func listRequestsKeepTheirOwnQuery() throws {
        for site in EHSite.allCases {
            let base = "https://\(site.host)"
            let disabled = "f_sft=on&f_sfu=on&f_sfl=on"
            let expected = [
                "front": "\(base)/?\(disabled)",
                "front-next": "\(base)/?next=103&\(disabled)",
                "front-seek": "\(base)/?seek=2024-01-01&\(disabled)",
                "category": "\(base)/?f_cats=1021&\(disabled)",
                "search": "\(base)/?f_search=language:chinese&\(disabled)",
                "search-advanced": "\(base)/?f_search=language:chinese&advsearch=1&f_sh=on&f_sto=on&f_sr=on&f_srdd=4"
                    + "&f_sp=on&f_spf=20&f_spt=200&\(disabled)",
                "popular": "\(base)/popular?\(disabled)",
                "tag": "\(base)/tag/language:chinese?\(disabled)",
                "uploader": "\(base)/uploader/someone?\(disabled)",
            ]
            let plan = steps(site)
            for (name, url) in expected {
                let step = try #require(plan.first { $0.fixturePath == "\(site.rawValue)/list/\(name).html" })
                #expect(step.request(fullContext(for: site))?.url.absoluteString == url, "\(name)")
            }
        }
    }

    @Test func followingTheNextLinkKeepsFiltersDisabled() throws {
        let next = try #require(steps(.eh).first { $0.fixturePath == "eh/list/front-next.html" })
        func request(_ link: String) -> String? {
            var context = CaptureContext()
            context.nextPageURL = URL(string: link)
            return next.request(context)?.url.absoluteString
        }
        // A plain link gets the three parameters.
        #expect(request("https://e-hentai.org/?next=103") == "https://e-hentai.org/?next=103&f_sft=on&f_sfu=on&f_sfl=on")
        // The link on a list requested unfiltered may carry them already: nothing is added or moved.
        let carried = "https://e-hentai.org/?f_sft=on&f_sfu=on&f_sfl=on&next=103"
        #expect(request(carried) == carried)
        // Partly there, repeated, off, or spelled as PHP reads the same name: each once, as on, in its first place.
        #expect(request("https://e-hentai.org/?f_sft=off&next=103&f.sfu=on&f_sft=on&f%5Fsfl=")
            == "https://e-hentai.org/?f_sft=on&next=103&f_sfu=on&f_sfl=on")
        // A name that only looks alike is another parameter.
        #expect(request("https://e-hentai.org/?F_SFT=on&next=103")
            == "https://e-hentai.org/?F_SFT=on&next=103&f_sft=on&f_sfu=on&f_sfl=on")
    }

    @Test func disablingFiltersStaysReadOnly() throws {
        for site in EHSite.allCases {
            let context = fullContext(for: site)
            for step in steps(site) where unfilteredListPaths(site).contains(step.fixturePath ?? "") {
                let request = try #require(step.request(context))
                #expect(request.method == "GET")
                #expect(request.body == nil)
                #expect(CapturePlan.isReadOnly(request, site: site), "\(step.fixturePath ?? "")")
                #expect(!CapturePlan.mentionsInlineSet(request))
            }
        }
    }
}
