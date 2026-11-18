import EHModels
import EHNetwork
import Foundation
import Testing

@testable import Eros

/// The replay of the checked-in fixtures that DEBUG UI tests run on (`-EROS_FIXTURE_REPLAY 1`): the Debug app bundle
/// carries them under `FixtureReplay/`, and `FixtureReplay` answers a request with the fixture captured for it, a
/// route's constructed page, or a 404. Nothing reaches the network.
@Suite struct FixtureReplayTests {
    /// The fixtures the copy script put into the app (the test host).
    private static let root = Bundle.main.resourceURL!.appending(
        path: FixtureReplay.bundleDirectory, directoryHint: .isDirectory
    )

    private static func replay(routes: [String: FixtureRoute] = [:]) throws -> FixtureReplay {
        try FixtureReplay(root: root, routes: routes)
    }

    private static func bytes(of path: String) throws -> Data {
        try Data(contentsOf: root.appending(path: path))
    }

    /// The answer is `status` with the bytes of the fixture at `path`.
    private static func expect(
        _ answer: FixtureReplayAnswer, serves path: String, status: Int = 200,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        #expect(answer.status == status, "\(path)", sourceLocation: sourceLocation)
        #expect(answer.body == (try bytes(of: path)), "\(path)", sourceLocation: sourceLocation)
    }

    private static func expectNotFound(
        _ answer: FixtureReplayAnswer, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(answer.status == 404, sourceLocation: sourceLocation)
        #expect(answer.body.isEmpty, sourceLocation: sourceLocation)
    }

    private static func get(_ text: String, from replay: FixtureReplay) -> FixtureReplayAnswer {
        replay.answer(method: "GET", url: URL(string: text)!, body: nil)
    }

    private static func apiPost(method: String, from replay: FixtureReplay) -> FixtureReplayAnswer {
        let body = Data(#"{"method":"\#(method)","text":"fake"}"#.utf8)
        return replay.answer(method: "POST", url: URL(string: "https://e-hentai.org/api.php")!, body: body)
    }

    @Test func debugBundleHoldsTheCheckedInFixtures() {
        let files = FileManager.default
        let paths = ["manifest.json", "eh/list/front.html", "ex/list/front.html", "constructed/eh/list-favorites.html"]
        for path in paths {
            #expect(files.fileExists(atPath: Self.root.appending(path: path).path(percentEncoded: false)), "\(path)")
        }
        #expect(!files.fileExists(atPath: Self.root.appending(path: "local").path(percentEncoded: false)))
    }

    @Test func capturedPagesMatchTheAppsOwnURLs() throws {
        let replay = try Self.replay()
        let pages: [(URL, String)] = [
            (ListQuery(source: .front).url(for: .eh), "eh/list/front.html"),
            (
                ListQuery(source: .toplist(.yesterday), position: .page(1)).url(for: .eh),
                "eh/list/toplist-yesterday-p1.html"
            ),
            (ListQuery(source: .front, position: .seek("2024-01-01")).url(for: .ex), "ex/list/front-seek.html"),
            (EHEndpoints.gallery(GalleryID(gid: 4_088_834, token: "930e52d088"), site: .eh), "eh/gallery/detail.html"),
        ]
        for (url, path) in pages {
            try Self.expect(replay.answer(method: "GET", url: url, body: nil), serves: path)
        }
    }

    @Test func queryOrderAndEncodingDoNotMatter() throws {
        let replay = try Self.replay()
        try Self.expect(
            Self.get("https://e-hentai.org/?f_search=language%3Achinese", from: replay), serves: "eh/list/search.html"
        )
        try Self.expect(
            Self.get("https://e-hentai.org/?f_sfl=on&f_search=language:chinese&f_sft=on&f_sfu=on", from: replay),
            serves: "eh/list/search.html"
        )
        // The captured URL is f_search=language:chinese&advsearch=1&f_sh=on&f_sto=on&f_sr=on&f_srdd=4&f_sp=on
        // &f_spf=20&f_spt=200&f_sft=on&f_sfu=on&f_sfl=on: the same set in another order and encoding matches.
        let shuffled = "https://e-hentai.org/?f_sfl=on&f_spt=200&advsearch=1&f_sh=on&f_search=language%3Achinese"
            + "&f_sto=on&f_sr=on&f_sft=on&f_srdd=4&f_sp=on&f_spf=20&f_sfu=on"
        try Self.expect(Self.get(shuffled, from: replay), serves: "eh/list/search-advanced.html")
        // With advsearch, f_sfl and the others are kept on both sides: one missing is another request. (A duplicate
        // would not tell: the comparison is of sets.)
        Self.expectNotFound(Self.get(shuffled.replacingOccurrences(of: "f_sfl=on&", with: ""), from: replay))
    }

    @Test func apiPostsAreChosenByMethod() throws {
        let replay = try Self.replay()
        try Self.expect(Self.apiPost(method: "tagsuggest", from: replay), serves: "eh/api/tagsuggest.json")
        try Self.expect(Self.apiPost(method: "gdata", from: replay), serves: "eh/api/gdata.json")
        Self.expectNotFound(Self.apiPost(method: "nosuch", from: replay))
    }

    @Test func redirectsAreReplayedWithTheirLocation() throws {
        let manifest = try JSONSerialization.jsonObject(with: Self.bytes(of: "manifest.json")) as? [String: Any]
        let entries = try #require(manifest?["entries"] as? [[String: Any]])
        let entry = try #require(entries.first { $0["path"] as? String == "eh/list/image-lookup-redirect.html" })
        let location = try #require(entry["location"] as? String)

        let answer = try Self.replay().answer(
            method: "POST", url: URL(string: "https://upld.e-hentai.org/image_lookup.php")!, body: Data("fake".utf8)
        )
        #expect(answer.status == 302)
        #expect(answer.headers["Location"] == location)
    }

    @Test func unknownRequestsAre404() throws {
        let replay = try Self.replay()
        Self.expectNotFound(Self.get("https://e-hentai.org/nothing", from: replay))
        Self.expectNotFound(Self.get("https://ehgt.org/fake.jpg", from: replay))
    }

    @Test func routesServeConstructedPages() throws {
        let replay = try Self.replay(routes: [
            "GET https://e-hentai.org/favorites.php": FixtureRoute(path: "constructed/eh/list-favorites.html"),
            "GET https://e-hentai.org/?f_search=fake%20ban": FixtureRoute(path: "constructed/eh/banned.txt"),
            "GET https://e-hentai.org/": FixtureRoute(path: "constructed/eh/http-429.html", status: 429),
        ])
        let favorites = Self.get("https://e-hentai.org/favorites.php", from: replay)
        try Self.expect(favorites, serves: "constructed/eh/list-favorites.html")
        #expect(favorites.headers["Content-Type"] == "text/html; charset=UTF-8")

        // The route's key is compared the same way: "+" and "%20" are both a space.
        let banned = Self.get("https://e-hentai.org/?f_search=fake+ban", from: replay)
        try Self.expect(banned, serves: "constructed/eh/banned.txt")
        #expect(banned.headers["Content-Type"] == "text/plain; charset=UTF-8")

        // A route goes before the captured front page (whose filter switches are dropped without advsearch).
        try Self.expect(
            Self.get("https://e-hentai.org/", from: replay), serves: "constructed/eh/http-429.html", status: 429
        )
    }

    /// `EROS_FIXTURE_ROUTES` may leave out `status` (200), `location` and `then` (none).
    @Test func routesDecodeWithTheirDefaults() throws {
        let json = #"{"GET https://e-hentai.org/": {"path": "constructed/eh/banned.txt"}}"#
        let routes = try JSONDecoder().decode([String: FixtureRoute].self, from: Data(json.utf8))
        #expect(routes == ["GET https://e-hentai.org/": FixtureRoute(path: "constructed/eh/banned.txt")])
        #expect(routes.values.first?.status == 200)
        #expect(routes.values.first?.then == nil)

        let later = #"{"GET https://e-hentai.org/popular": "#
            + #"{"path": "eh/list/search-empty.html", "then": "eh/list/front.html"}}"#
        let thenRoutes = try JSONDecoder().decode([String: FixtureRoute].self, from: Data(later.utf8))
        #expect(thenRoutes.values.first == FixtureRoute(path: "eh/list/search-empty.html", then: "eh/list/front.html"))
    }

    /// A route with `then` answers the first request it matches with `path`, and every one after with `then` (M2
    /// review F4 I-2: a refresh that asks again gets another page). The count is the replay's, whichever copy answers:
    /// the URL protocol's registry holds one.
    @Test func aRouteWithThenAnswersItFromTheSecondRequestOn() throws {
        let replay = try Self.replay(routes: [
            "GET https://e-hentai.org/popular": FixtureRoute(
                path: "eh/list/search-empty.html", then: "eh/list/front.html"
            ),
            "GET https://e-hentai.org/": FixtureRoute(path: "constructed/eh/list-favorites.html"),
        ])
        try Self.expect(Self.get("https://e-hentai.org/popular", from: replay), serves: "eh/list/search-empty.html")
        // Another route, and the fixtures, neither count for it nor change.
        try Self.expect(Self.get("https://e-hentai.org/", from: replay), serves: "constructed/eh/list-favorites.html")
        try Self.expect(
            Self.get("https://e-hentai.org/?f_search=language%3Achinese", from: replay), serves: "eh/list/search.html"
        )
        let copy = replay
        try Self.expect(Self.get("https://e-hentai.org/popular", from: copy), serves: "eh/list/front.html")
        try Self.expect(Self.get("https://e-hentai.org/popular", from: replay), serves: "eh/list/front.html")
        try Self.expect(Self.get("https://e-hentai.org/", from: replay), serves: "constructed/eh/list-favorites.html")
    }

    /// Without `then` a route answers every request it matches alike, as it always did.
    @Test func aRouteWithoutThenAnswersAlikeEveryTime() throws {
        let replay = try Self.replay(routes: [
            "GET https://e-hentai.org/popular": FixtureRoute(path: "eh/list/search-empty.html"),
        ])
        for _ in 0..<3 {
            try Self.expect(Self.get("https://e-hentai.org/popular", from: replay), serves: "eh/list/search-empty.html")
        }
    }

    /// Through the app's own client: the route's first page, then its `then` page.
    @MainActor @Test func theClientReadsARoutesLaterPage() async throws {
        let routes = [
            "GET https://e-hentai.org/popular": FixtureRoute(
                path: "eh/list/search-empty.html", then: "eh/list/front.html"
            ),
        ]
        let environment = try Self.replayingEnvironment(routes: routes)
        await environment.start()
        let first = try await environment.service.galleryList(ListQuery(source: .popular), site: .eh)
        #expect(first.items.isEmpty)
        let again = try await environment.service.galleryList(ListQuery(source: .popular), site: .eh)
        #expect(again.items.count == 25)
    }

    /// A route to a file that is not there fails at once, not as an empty page later; so does a `then` to one.
    @Test func routesToMissingFilesAreRefused() {
        #expect(throws: (any Error).self) {
            try Self.replay(routes: ["GET https://e-hentai.org/": FixtureRoute(path: "constructed/eh/nothing.html")])
        }
        #expect(throws: (any Error).self) {
            try Self.replay(routes: ["GET https://e-hentai.org/": FixtureRoute(path: "../manifest.json")])
        }
        #expect(throws: FixtureReplayError.missingFile("constructed/eh/nothing.html")) {
            try Self.replay(routes: [
                "GET https://e-hentai.org/": FixtureRoute(
                    path: "eh/list/front.html", then: "constructed/eh/nothing.html"
                ),
            ])
        }
    }

    /// A manifest entry that is a request the replay cannot read (here a URL without a scheme or a host) stops the
    /// replay at once instead of leaving that request unanswered later; an entry that is no request (neither a method
    /// nor a URL) is left out.
    @Test func unreadableManifestEntriesAreRefused() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "eros-tests-replay-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("<html></html>".utf8).write(to: directory.appending(path: "page.html"))
        func write(_ entries: String) throws {
            try Data(#"{"entries": [\#(entries)]}"#.utf8).write(to: directory.appending(path: "manifest.json"))
        }

        try write(#"{"path": "page.html"}"#)
        let replay = try FixtureReplay(root: directory)
        Self.expectNotFound(Self.get("https://e-hentai.org/", from: replay))
        for entry in [
            #"{"path": "page.html", "method": "GET", "url": "e-hentai.org/no-scheme"}"#,
            #"{"path": "page.html", "method": "GET"}"#,
            #"{"path": "page.html", "url": "https://e-hentai.org/"}"#,
        ] {
            try write(entry)
            #expect(throws: FixtureReplayError.invalidEntry("page.html"), Comment(rawValue: entry)) {
                try FixtureReplay(root: directory)
            }
        }
    }

    /// An api.php POST of the app's own service (its body a stream by then) is answered from the replay.
    @MainActor @Test func theServicesAPIPostsAreReplayed() async throws {
        let environment = try Self.replayingEnvironment()
        await environment.start()
        let tags = try await environment.service.tagSuggestions("chin", site: .eh)
        #expect(!tags.isEmpty)
        #expect(tags.contains(TagRef(namespace: "language", name: "chinese")))
    }

    @MainActor @Test func theClientReadsReplayedPages() async throws {
        let environment = try Self.replayingEnvironment()
        await environment.start()
        let page = try await environment.service.galleryList(ListQuery(source: .front), site: .eh)
        #expect(page.items.count == 25)
    }

    @MainActor @Test func replayedImageSessionsGet404() async throws {
        let environment = try Self.replayingEnvironment()
        let session = URLSession(
            configuration: EHClient.makeSessionConfiguration(for: .eh, configuration: environment.clientConfiguration)
        )
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: URL(string: "https://ehgt.org/fake.jpg")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }

    private static let userAgent =
        "Mozilla/5.0 (FakePhone; CPU iPhone OS 27_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    /// The UI testing environment with the replay (and `routes`) in front (a stub UA probe: no WebView needed).
    @MainActor private static func replayingEnvironment(
        routes: [String: FixtureRoute] = [:]
    ) throws -> AppEnvironment {
        AppEnvironment(
            uiTesting: true,
            sessionConfigurator: FixtureReplayURLProtocol.configurator(serving: try replay(routes: routes)),
            userAgentProbe: { userAgent }
        )
    }
}
