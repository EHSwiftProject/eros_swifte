import EHModels
import EHNetwork
import EHParsing
import FixtureCaptureCore
import Foundation
import Testing

private func capturer(
    _ transport: StubTransport,
    sites: Set<EHSite> = [.eh],
    targets: CaptureTargets = CaptureFakes.targets()
) throws -> Capturer {
    Capturer(transport: transport, credentials: try CaptureFakes.credentials(sites: sites), targets: targets)
}

private let banNotice = "Your IP address has been temporarily banned for excessive pageloads which indicates that you are "
    + "using automated mirroring/harvesting software. The ban expires in 59 minutes and 48 seconds"

/// A canned EH site whose `index`-th answer is replaced.
private func canned(replacing index: Int, with response: CaptureResponse, site: CannedSite = CannedSite()) -> StubTransport {
    StubTransport { request, i in i == index ? response : site.respond(request) }
}

@Suite struct CapturerTests {
    @Test func abortsWhenFrontPageIsNotCompact() async throws {
        let transport = StubTransport(responses: [CannedSite.html(CannedSite.listPage(mode: "t"))])
        await #expect(throws: CaptureAbort.notCompactView(site: .eh, mode: .thumbnail)) {
            try await capturer(transport).run(sites: [.eh])
        }
        #expect(transport.requests.count == 1)
    }

    @Test func abortsWhenDisplayModeUnknown() async throws {
        let transport = StubTransport(responses: [CannedSite.html(CannedSite.listPage(mode: nil))])
        await #expect(throws: CaptureAbort.notCompactView(site: .eh, mode: nil)) {
            try await capturer(transport).run(sites: [.eh])
        }
        #expect(transport.requests.count == 1)
    }

    @Test func stopsImmediatelyOn429() async throws {
        let transport = canned(replacing: 1, with: CannedSite.html("<html><body>slow down</body></html>", status: 429))
        await #expect(throws: CaptureAbort.stoppedByServer(site: .eh, fixturePath: "eh/list/front-next.html", status: 429)) {
            try await capturer(transport).run(sites: [.eh])
        }
        #expect(transport.requests.count == 2)
    }

    @Test(arguments: [509, 500, 503, 599])
    func stopsImmediatelyOnServerErrors(status: Int) async throws {
        let transport = canned(replacing: 2, with: CannedSite.html("<html><body>error</body></html>", status: status))
        await #expect(throws: CaptureAbort.stoppedByServer(site: .eh, fixturePath: "eh/list/front-seek.html", status: status)) {
            try await capturer(transport).run(sites: [.eh])
        }
        #expect(transport.requests.count == 3)
    }

    @Test func stopsOnBannedBody() async throws {
        let transport = canned(replacing: 1, with: CannedSite.html(banNotice))
        await #expect(throws: CaptureAbort.banned(site: .eh, fixturePath: "eh/list/front-next.html")) {
            try await capturer(transport).run(sites: [.eh])
        }
        #expect(transport.requests.count == 2)
    }

    @Test func unexpectedStatusAborts() async throws {
        let site = CannedSite()
        let transport = StubTransport { request, _ in
            request.url.path() == "/g/123/abcdef0123/" && request.url.query() == nil
                ? CannedSite.html("<html><body>Forbidden</body></html>", status: 403)
                : site.respond(request)
        }
        await #expect(throws: CaptureAbort.unexpectedStatus(site: .eh, fixturePath: "eh/gallery/detail.html", status: 403)) {
            try await capturer(transport).run(sites: [.eh])
        }
        #expect(transport.requests.count == 20)
    }

    @Test func abortsExWhenFrontPageIsEmpty() async throws {
        let transport = StubTransport(responses: [CannedSite.html("")])
        await #expect(throws: CaptureAbort.exAccessDenied) {
            try await capturer(transport, sites: [.ex]).run(sites: [.ex])
        }
        #expect(transport.requests.count == 1)

        let notHTML = StubTransport(responses: [CannedSite.html("sad panda")])
        await #expect(throws: CaptureAbort.exAccessDenied) {
            try await capturer(notHTML, sites: [.ex]).run(sites: [.ex])
        }
    }

    @Test func checksRunInTheBriefsOrder() async throws {
        // A server error wins over a ban notice.
        let both = StubTransport(responses: [CannedSite.html(banNotice, status: 503)])
        await #expect(throws: CaptureAbort.stoppedByServer(site: .eh, fixturePath: "eh/list/front.html", status: 503)) {
            try await capturer(both).run(sites: [.eh])
        }
        // A ban notice wins over ExHentai's empty front page check.
        let bannedEX = StubTransport(responses: [CannedSite.html(banNotice)])
        await #expect(throws: CaptureAbort.banned(site: .ex, fixturePath: "ex/list/front.html")) {
            try await capturer(bannedEX, sites: [.ex]).run(sites: [.ex])
        }
        // ExHentai's empty front page wins over its status.
        let emptyEX = StubTransport(responses: [CannedSite.html("", status: 403)])
        await #expect(throws: CaptureAbort.exAccessDenied) {
            try await capturer(emptyEX, sites: [.ex]).run(sites: [.ex])
        }
        // The status wins over the display mode.
        let forbidden = StubTransport(responses: [CannedSite.html(CannedSite.listPage(mode: "t"), status: 403)])
        await #expect(throws: CaptureAbort.unexpectedStatus(site: .eh, fixturePath: "eh/list/front.html", status: 403)) {
            try await capturer(forbidden).run(sites: [.eh])
        }
        // "banned" in a JSON answer or an HTML page is not a ban notice.
        let site = CannedSite()
        let json = CaptureResponse(
            status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"error":"banned"}"#.utf8),
            url: URL(string: "https://e-hentai.org/api.php")!
        )
        let notBanned = StubTransport { request, _ in
            if request.url.path() == "/api.php" { return json }
            if request.url.path() == "/popular" { return CannedSite.html("<html><body>banned words</body></html>") }
            return site.respond(request)
        }
        let report = try await capturer(notBanned).run(sites: [.eh])
        #expect(report.captures.count == 37)
    }

    @Test func missingDependencySkipsStep() async throws {
        let transport = StubTransport { request, _ in CannedSite(detailHasImagePages: false).respond(request) }
        let report = try await capturer(transport).run(sites: [.eh])
        let skipped = report.skipped.map(\.fixturePath)
        #expect(skipped == [
            "eh/gallery/content-warning.html", "eh/image/page.html", "eh/image/page-nl.html", "eh/api/showpage.json",
        ])
        #expect(report.skipped.allSatisfy { !$0.reason.isEmpty })
        #expect(report.skipped.first?.reason == "no contentWarningGallery in targets.json")
        #expect(report.captures.count == 34)
        // Skipped steps send nothing.
        #expect(!transport.requests.contains { $0.url.path().hasPrefix("/s/") })
    }

    @Test func recordsCapturesInPlanOrder() async throws {
        let site = CannedSite()
        let transport = StubTransport { request, _ in site.respond(request) }
        let report = try await capturer(transport, targets: CaptureFakes.targets(contentWarning: true)).run(sites: [.eh])
        let plan = CapturePlan.steps(for: .eh, targets: CaptureFakes.site(.eh, contentWarning: true))
        #expect(report.captures.map(\.fixturePath) == plan.compactMap(\.fixturePath))
        #expect(report.skipped.isEmpty)
        #expect(transport.requests.count == 39)
        let lookup = report.captures.first { $0.fixturePath == "eh/list/image-lookup-redirect.html" }
        #expect(lookup?.status == 302)
        #expect(lookup?.method == "POST")
        // The image lookup posts the downloaded cover.
        let cover = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
        let posted = transport.requests.first { $0.url.host() == "upld.e-hentai.org" }?.body
        #expect(posted.map { $0.range(of: cover) != nil } == true)
        #expect(report.warnings.isEmpty)
    }

    @Test func archiverLinkWithoutOrKeyIsStillCaptured() async throws {
        for (hasOrKey, query) in [(false, "gid=123&token=abcdef0123"), (true, "gid=123&token=abcdef0123&or=474357--a8c5d0")] {
            let site = CannedSite(archiverHasOrKey: hasOrKey)
            let transport = StubTransport { request, _ in site.respond(request) }
            let report = try await capturer(transport).run(sites: [.eh])
            let archiver = transport.requests.filter { $0.url.path() == "/archiver.php" }
            #expect(archiver.map(\.url) == [URL(string: "https://e-hentai.org/archiver.php?\(query)")!])
            #expect(archiver.allSatisfy { $0.method == "GET" })
            #expect(report.captures.contains { $0.fixturePath == "eh/popup/archiver.html" })
            #expect(!report.skipped.contains { $0.fixturePath == "eh/popup/archiver.html" })
        }
    }

    @Test func imageLookupPostsTheCoverInItsOwnFormat() async throws {
        let webp = Data(Array("RIFF".utf8) + [0x24, 0, 0, 0] + Array("WEBPVP8 ".utf8))
        let cases: [(contentType: String?, bytes: Data, fileName: String, mimeType: String)] = [
            ("image/webp", webp, "a.webp", "image/webp"),
            (nil, webp, "a.webp", "image/webp"),
            ("image/jpeg", CannedSite.jpegCover, "a.jpg", "image/jpeg"),
        ]
        for (index, item) in cases.enumerated() {
            let site = CannedSite(coverContentType: item.contentType, coverBytes: item.bytes)
            let transport = StubTransport { request, _ in site.respond(request) }
            let report = try await capturer(transport).run(sites: [.eh])
            let body = transport.requests.first { $0.url.host() == "upld.e-hentai.org" }?.body ?? Data()
            let text = String(decoding: body, as: UTF8.self)
            let named = text.contains(#"filename="\#(item.fileName)""#) && text.contains("Content-Type: \(item.mimeType)\r\n")
            #expect(named, "case \(index)")
            #expect(body.range(of: item.bytes) != nil, "case \(index): the cover is not posted")
            #expect(report.warnings.isEmpty, "case \(index)")
        }
    }

    @Test func unrecognizedCoverWarnsWithoutValues() async throws {
        let site = CannedSite(coverContentType: "application/x-zqfake-type", coverBytes: Data([0x00, 0x01, 0x02, 0x03]))
        let transport = StubTransport { request, _ in site.respond(request) }
        let report = try await capturer(transport).run(sites: [.eh])
        let body = String(decoding: transport.requests.first { $0.url.host() == "upld.e-hentai.org" }?.body ?? Data(), as: UTF8.self)
        #expect(body.contains(#"filename="a.jpg""#))
        #expect(report.warnings.count == 1)
        #expect(report.warnings.allSatisfy { $0.hasPrefix("eh cover image:") })
        let leaks = report.warnings.contains { $0.contains("zqfake") }
        #expect(!leaks, "the warning repeats the Content-Type")
        // The lookup still ran.
        #expect(report.captures.contains { $0.fixturePath == "eh/list/image-lookup-redirect.html" })
    }

    @Test func addsDefaultHeadersAndScopedCookies() async throws {
        let site = CannedSite()
        let transport = StubTransport { request, _ in site.respond(request) }
        _ = try await capturer(transport, targets: CaptureFakes.targets(contentWarning: true)).run(sites: [.eh])
        let requests = transport.requests
        let contentWarning = URL(string: "https://e-hentai.org/g/456/0123456789/")!

        let siteRequests = requests.filter { $0.url.host() == "e-hentai.org" }
        #expect(siteRequests.count == 37)
        let defaultHeaders = requests.allSatisfy { request in
            request.headers["User-Agent"] == RequestDefaults.chromeUserAgent
                && request.headers["Accept"] == RequestDefaults.accept
                && request.headers["Accept-Language"] == RequestDefaults.acceptLanguage
                && request.timeout == RequestDefaults.timeouts(for: .eh).receive
        }
        #expect(defaultHeaders, "a request lacks the default headers or timeout")
        let siteCookies = siteRequests.filter { $0.url != contentWarning }.allSatisfy { request in
            let cookie = request.headers["Cookie"] ?? ""
            return cookie.hasPrefix("nw=1; ") && cookie.contains("ipb_member_id=") && cookie.contains("ipb_pass_hash=")
        }
        #expect(siteCookies, "a site request lacks nw=1 or the login cookies")

        let cover = requests.filter { $0.url.host() == "ehgt.org" }
        #expect(cover.count == 1)
        let coverHasNoCookie = cover.allSatisfy { $0.headers["Cookie"] == nil }
        #expect(coverHasNoCookie, "the cover request carries cookies")

        let warning = requests.filter { $0.url == contentWarning }
        #expect(warning.count == 1)
        let warningOmitsNW = warning.allSatisfy { request in
            let cookie = request.headers["Cookie"] ?? ""
            return !cookie.contains("nw=") && cookie.contains("ipb_member_id=")
        }
        #expect(warningOmitsNW, "the content warning request sends nw or lacks the login cookies")

        let forum = requests.filter { $0.url.host() == "forums.e-hentai.org" }
        #expect(forum.isEmpty, "the plan requests the forum host")
    }

    @Test func requestsAreSerial() async throws {
        let site = CannedSite()
        let transport = StubTransport { request, _ in site.respond(request) }
        _ = try await capturer(transport).run(sites: [.eh])
        #expect(transport.requests.count == 38)
        #expect(transport.maxConcurrency == 1)
    }

    @Test func capturesSitesInArgumentOrder() async throws {
        let eh = CannedSite(site: .eh)
        let ex = CannedSite(site: .ex)
        let transport = StubTransport { request, _ in
            let host = request.url.host() ?? ""
            return host.hasSuffix("exhentai.org") ? ex.respond(request) : eh.respond(request)
        }
        let report = try await capturer(transport, sites: [.eh, .ex]).run(sites: [.ex, .eh])
        let sites = report.captures.map(\.site)
        #expect(sites == Array(repeating: .ex, count: 31) + Array(repeating: .eh, count: 37))
        #expect(transport.maxConcurrency == 1)
    }

    @Test func refusesExtractedRequestsThatWouldChangeSettings() async throws {
        let site = CannedSite()
        let front = CannedSite.html(CannedSite.listPage(mode: "l", nextHref: "https://e-hentai.org/?inline_set=dm_t"))
        let transport = canned(replacing: 0, with: front, site: site)
        let report = try await capturer(transport).run(sites: [.eh])
        #expect(report.skipped.map(\.fixturePath).contains("eh/list/front-next.html"))
        let sent = transport.requests.contains { $0.url.absoluteString.contains("inline_set") }
        #expect(!sent, "a request with inline_set was sent")
    }

    @Test func ignoresExtractedLinksToOtherHosts() async throws {
        let site = CannedSite()
        let front = CannedSite.html(CannedSite.listPage(mode: "l", nextHref: "https://example.org/?next=104"))
        let transport = canned(replacing: 0, with: front, site: site)
        let report = try await capturer(transport).run(sites: [.eh])
        #expect(report.skipped.map(\.fixturePath).contains("eh/list/front-next.html"))
        #expect(!transport.requests.contains { $0.url.host() == "example.org" })
    }

    @Test func transportErrorsAbortWithoutSecrets() async throws {
        struct Leaky: LocalizedError {
            var errorDescription: String? {
                "failed: https://e-hentai.org/g/123/abcdef0123/?uid=\(CaptureFakes.memberID) "
                    + "Cookie: ipb_pass_hash=\(CaptureFakes.passHash)"
            }
        }
        let site = CannedSite()
        let transport = StubTransport { request, index in
            if index == 3 { throw Leaky() }
            return site.respond(request)
        }
        var message = ""
        var path = ""
        do {
            _ = try await capturer(transport).run(sites: [.eh])
        } catch let CaptureAbort.transport(site, fixturePath, text) {
            #expect(site == .eh)
            path = fixturePath
            message = text
        }
        #expect(path == "eh/list/category.html")
        #expect(transport.requests.count == 4)
        let leaks = message.contains(CaptureFakes.memberID) || message.contains(CaptureFakes.passHash)
        #expect(!leaks, "the transport message contains a credential")
        #expect(!message.isEmpty)
    }

    @Test func exImageLookupWithoutAFormUsesTheSitesOwnEndpoint() async throws {
        let ex = CannedSite(site: .ex)
        let front = CannedSite.html(CannedSite.listPage(mode: "l", host: "exhentai.org", lookupAction: ""))
        let transport = canned(replacing: 0, with: front, site: ex)
        let report = try await capturer(transport, sites: [.ex]).run(sites: [.ex])
        let lookup = transport.requests.filter { $0.method == "POST" && $0.url.lastPathComponent == "image_lookup.php" }
        #expect(lookup.map(\.url) == [URL(string: "https://exhentai.org/upld/image_lookup.php")!])
        let browserLike = lookup.allSatisfy { request in
            request.headers["Referer"] == "https://exhentai.org/" && (request.headers["Cookie"] ?? "").contains("igneous=")
        }
        #expect(browserLike, "the lookup lacks the Referer or the ExHentai cookies")
        #expect(report.captures.contains { $0.fixturePath == "ex/list/image-lookup.html" })
    }

    @Test(arguments: [EHSite.eh, .ex], [403, 404, 400])
    func clientErrorFromTheImageLookupSkipsItAndItsResultPage(site: EHSite, status: Int) async throws {
        let canned = CannedSite(site: site, lookupStatus: status)
        let transport = StubTransport { request, _ in canned.respond(request) }
        let report = try await capturer(transport, sites: [site]).run(sites: [site])
        let s = site.rawValue
        let lookupSkip = report.skipped.first { $0.fixturePath == "\(s)/list/image-lookup-redirect.html" }
        #expect(lookupSkip?.reason == "image lookup returned HTTP \(status); skipped")
        #expect(report.skipped.contains { $0.fixturePath == "\(s)/list/image-lookup.html" })
        // Everything else is captured as usual, including the steps after the lookup.
        let paths = Set(report.captures.map(\.fixturePath))
        #expect(!paths.contains("\(s)/list/image-lookup-redirect.html") && !paths.contains("\(s)/list/image-lookup.html"))
        #expect(paths.isSuperset(of: ["\(s)/account/uconfig.html", "\(s)/account/mytags.html"]))
        #expect(report.captures.count == (site == .eh ? 35 : 29))
        // One warning naming the step and the status, never a value.
        #expect(report.warnings == ["\(s) image lookup: \(s)/list/image-lookup-redirect.html returned HTTP \(status); skipped"])
        let leaks = report.warnings.contains { warning in
            [CaptureFakes.memberID, CaptureFakes.passHash, CaptureFakes.igneous, "f_shash"].contains { warning.contains($0) }
        }
        #expect(!leaks)
    }

    @Test func clientErrorFromTheLookupResultPageSkipsOnlyIt() async throws {
        let canned = CannedSite(lookupResultStatus: 404)
        let transport = StubTransport { request, _ in canned.respond(request) }
        let report = try await capturer(transport).run(sites: [.eh])
        // The content warning step is skipped anyway: these targets have none.
        #expect(report.skipped.map(\.fixturePath) == ["eh/gallery/content-warning.html", "eh/list/image-lookup.html"])
        #expect(report.skipped.last?.reason == "image lookup returned HTTP 404; skipped")
        #expect(report.captures.contains { $0.fixturePath == "eh/list/image-lookup-redirect.html" })
        #expect(report.captures.count == 36)
    }

    @Test(arguments: [500, 503, 429, 509])
    func serverErrorsFromTheImageLookupStillStopTheRun(status: Int) async throws {
        let canned = CannedSite(lookupStatus: status)
        let transport = StubTransport { request, _ in canned.respond(request) }
        await #expect(throws: CaptureAbort.stoppedByServer(site: .eh, fixturePath: "eh/list/image-lookup-redirect.html", status: status)) {
            try await capturer(transport).run(sites: [.eh])
        }
        #expect(!transport.requests.contains { $0.url.path() == "/uconfig.php" })
    }

    @Test func banNoticeFromTheImageLookupStillStopsTheRun() async throws {
        let site = CannedSite()
        let transport = StubTransport { request, _ in
            request.url.lastPathComponent == "image_lookup.php"
                ? CannedSite.html("Your IP address has been temporarily banned for excessive pageloads.", status: 403, url: request.url)
                : site.respond(request)
        }
        await #expect(throws: CaptureAbort.banned(site: .eh, fixturePath: "eh/list/image-lookup-redirect.html")) {
            try await capturer(transport).run(sites: [.eh])
        }
    }

    @Test func usesTheFileSearchFormOfTheFrontPage() async throws {
        // A form on ExHentai's own host is used as it is (here a path other than the fallback's); one on its upload
        // host is not a lookup host of ExHentai (see `CapturePlan.isImageLookupURL`), so the fallback is used.
        let exCases = [
            ("https://exhentai.org/image_lookup.php", "https://exhentai.org/image_lookup.php"),
            ("https://upld.exhentai.org/upld/image_lookup.php", "https://exhentai.org/upld/image_lookup.php"),
        ]
        for (action, expected) in exCases {
            let ex = CannedSite(site: .ex)
            let front = CannedSite.html(CannedSite.listPage(mode: "l", host: "exhentai.org", lookupAction: action))
            let exTransport = canned(replacing: 0, with: front, site: ex)
            _ = try await capturer(exTransport, sites: [.ex]).run(sites: [.ex])
            let exLookup = exTransport.requests.filter { $0.method == "POST" && $0.url.lastPathComponent == "image_lookup.php" }
            #expect(exLookup.map(\.url) == [URL(string: expected)!], "\(action)")
        }

        // A form elsewhere, or not over https, is ignored for the Flutter app's address.
        for action in ["https://upld.example.org/image_lookup.php", "http://upld.e-hentai.org/x/image_lookup.php",
                       "https://upld.e-hentai.org/upload.php?image_lookup.php"] {
            let site = CannedSite()
            let front = CannedSite.html(CannedSite.listPage(mode: "l", lookupAction: action))
            let transport = canned(replacing: 0, with: front, site: site)
            let report = try await capturer(transport).run(sites: [.eh])
            let lookup = transport.requests.filter { $0.method == "POST" && $0.url.lastPathComponent == "image_lookup.php" }
            #expect(lookup.map(\.url) == [URL(string: "https://upld.e-hentai.org/image_lookup.php")!], "\(action) was used")
            #expect(report.captures.count == 37)
        }
    }

    // Request indexes without a content warning target: 1 front-next, 9 tag, 14 detail, 20 mpv, 31 mytags (the
    // last request).
    @Test(arguments: [
        (index: 1, body: ""), (index: 1, body: "sad panda"), (index: 9, body: ""), (index: 14, body: ""),
        (index: 20, body: ""), (index: 31, body: ""),
    ])
    func exPagesThatComeBackEmptyStopTheRun(index: Int, body: String) async throws {
        let site = CannedSite(site: .ex)
        let transport = StubTransport { request, i in
            i == index ? CannedSite.html(body, url: request.url) : site.respond(request)
        }
        await #expect(throws: CaptureAbort.exAccessDenied) {
            try await capturer(transport, sites: [.ex]).run(sites: [.ex])
        }
        #expect(transport.requests.count == index + 1)
    }

    @Test func exNotFoundMayBePlainTextButNotEmpty() async throws {
        let site = CannedSite(site: .ex)
        let plain = StubTransport { request, _ in site.respond(request) }
        let report = try await capturer(plain, sites: [.ex]).run(sites: [.ex])
        #expect(report.captures.contains { $0.fixturePath == "ex/gallery/not-found.html" })

        let empty = StubTransport { request, _ in
            request.url.path() == "/g/1/0000000000/" ? CannedSite.html("", url: request.url) : site.respond(request)
        }
        await #expect(throws: CaptureAbort.exAccessDenied) {
            try await capturer(empty, sites: [.ex]).run(sites: [.ex])
        }
        // EH has no such rule.
        let eh = CannedSite()
        let ehEmpty = StubTransport { request, _ in
            request.url.path() == "/popular" ? CannedSite.html("", url: request.url) : eh.respond(request)
        }
        #expect(try await capturer(ehEmpty).run(sites: [.eh]).captures.count == 37)
    }

    @Test func reportsPrintWithoutValues() async throws {
        let site = CannedSite()
        let transport = StubTransport { request, _ in site.respond(request) }
        let report = try await capturer(transport).run(sites: [.eh])
        let printed = [
            String(describing: report), String(reflecting: report), String(describing: transport.requests),
            String(reflecting: transport.requests), String(describing: report.captures),
        ].joined()
        var dumped = ""
        dump(transport.requests, to: &dumped)
        let leaks = (printed + dumped).contains(CaptureFakes.memberID) || (printed + dumped).contains(CaptureFakes.passHash)
            || (printed + dumped).contains(CaptureFakes.apikey)
        #expect(!leaks, "printing a report or request shows a value")
    }
}
