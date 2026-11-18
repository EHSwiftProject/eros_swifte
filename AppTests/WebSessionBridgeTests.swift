import EHModels
import EHNetwork
import Foundation
import Testing
import WebKit

@testable import Eros

/// Runs inside the Eros app on the simulator, each test on its own non-persistent WebKit store; nothing loads a page,
/// so nothing reaches the network. Every cookie value is made up ("<name>-fake-…", member id 1234567).
///
/// Each test has five minutes (`.timeLimit`): some hold a page or a WebKit store call until they let it go, and one
/// that never lets go must fail at the limit, not hang the run (the test process is then ended and started again
/// for the tests after it); five, as WebKit's processes are slow on a busy host (an account flow test once took
/// 143 s under a heavy load), and as `scripts/test.sh` gives a test by default.
@MainActor @Suite(.timeLimit(.minutes(5))) struct WebSessionBridgeTests {
    private static let memberID = "1234567"
    private static let passHash = "0123456789abcdef0123456789abcdef"
    private static let identity = [CookieNames.memberID: memberID, CookieNames.passHash: passHash]
    private static let webKitUserAgent = "Mozilla/5.0 (FakePhone) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    private struct Harness {
        let bridge: WebSessionBridge
        let store: CookieStore
        let userAgents: UserAgentStore
        let vault: InMemoryVault

        /// The WebView's cookies as (domain, name) → value, read past the bridge within `WebKitTestCalls.limit`.
        func webCookies(sourceLocation: SourceLocation = #_sourceLocation) async -> [String: String] {
            var result: [String: String] = [:]
            for cookie in await allWebCookies(sourceLocation: sourceLocation) {
                result["\(cookie.domain) \(cookie.name)"] = cookie.value
            }
            return result
        }

        /// The WebView's cookies, read past the bridge within `WebKitTestCalls.limit`.
        func allWebCookies(sourceLocation: SourceLocation = #_sourceLocation) async -> [HTTPCookie] {
            await WebKitTestCalls.allCookies(of: bridge.dataStore.httpCookieStore, sourceLocation: sourceLocation)
        }

        /// Puts a cookie into the WebView store, past the bridge, within `WebKitTestCalls.limit`.
        func put(
            _ name: String, _ value: String, domain: String, sourceLocation: SourceLocation = #_sourceLocation
        ) async throws {
            let cookie = try #require(HTTPCookie(properties: [
                .name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE",
            ]))
            try await WebKitTestCalls.setCookie(
                cookie, in: bridge.dataStore.httpCookieStore, sourceLocation: sourceLocation
            )
        }

        func jar(_ site: EHSite) async -> [String: String] {
            await store.snapshot().cookies[site] ?? [:]
        }
    }

    /// A loaded store with the given jars; the WebKit UA adopted unless `webKit` is false (the Chrome fallback).
    /// `webStore` and `storeTimeout` go to the bridge (WebKit's own calls and `roomyTestTimeout` by default).
    private static func makeHarness(
        eh: [String: String] = [:], ex: [String: String] = [:], webKit: Bool = true,
        webStore: (any WebStoreAccess)? = nil, storeTimeout: Duration = WebSessionBridge.roomyTestTimeout
    ) async throws -> Harness {
        let vault = InMemoryVault()
        let store = CookieStore(vault: vault)
        try await store.load()
        if !eh.isEmpty { try await store.set(eh, for: [.eh]) }
        if !ex.isEmpty { try await store.set(ex, for: [.ex]) }
        let userAgents = UserAgentStore(cache: InMemoryUserAgentCache(), systemVersion: "27.0")
        if webKit {
            #expect(await userAgents.adopt(webKitUserAgent))
        }
        let bridge = WebSessionBridge(
            store: store, userAgents: userAgents, webStore: webStore, storeTimeout: storeTimeout
        )
        let harness = Harness(bridge: bridge, store: store, userAgents: userAgents, vault: vault)
        #expect(await harness.allWebCookies().isEmpty)
        return harness
    }

    // MARK: - Push

    @Test func pushCopiesBothJarsIntoTheWebView() async throws {
        let eh = Self.identity.merging(["sk": "sk-fake-0001", "sp": "5"]) { $1 }
        let ex = Self.identity.merging([CookieNames.igneous: "igneous-fake-0002"]) { $1 }
        let h = try await Self.makeHarness(eh: eh, ex: ex)
        try await h.bridge.push()
        var expected: [String: String] = [".e-hentai.org nw": "1", ".exhentai.org nw": "1"]
        for (name, value) in eh { expected[".e-hentai.org \(name)"] = value }
        for (name, value) in ex { expected[".exhentai.org \(name)"] = value }
        #expect(await h.webCookies() == expected)
        let cookies = await h.allWebCookies()
        #expect(cookies.allSatisfy { $0.path == "/" && $0.isSecure })
        // The jar does not store nw.
        #expect(await h.jar(.eh) == eh)
        #expect(await h.jar(.ex) == ex)
    }

    @Test func pushSkipsTheClearanceCookies() async throws {
        let clearance = [CookieNames.clearance: "clearance-fake-0001", "cf_duid": "duid-fake-0002"]
        let h = try await Self.makeHarness(
            eh: Self.identity.merging(clearance) { $1 }, ex: Self.identity.merging(clearance) { $1 }
        )
        try await h.bridge.push()
        let names = await h.allWebCookies().map(\.name)
        #expect(!names.contains(CookieNames.clearance))
        #expect(!names.contains("cf_duid"))
        #expect(names.filter { $0 == CookieNames.memberID }.count == 2)
        #expect(await h.jar(.eh)[CookieNames.clearance] == "clearance-fake-0001")
    }

    @Test func pushSkipsEveryUserAgentBoundCloudflareCookie() async throws {
        let bound = ["__cf_bm": "bm-fake-0001", "_cfuvid": "uvid-fake-0002", "cf_chl_prog": "chl-fake-0003"]
        let h = try await Self.makeHarness(eh: Self.identity.merging(bound) { $1 }.merging(["sk": "sk-fake-0004"]) { $1 })
        try await h.bridge.push()
        let names = await h.allWebCookies().map(\.name)
        for name in bound.keys { #expect(!names.contains(name), Comment(rawValue: name)) }
        #expect(names.contains("sk"))
        #expect(await h.jar(.eh)["__cf_bm"] == "bm-fake-0001")
    }

    // MARK: - Pull

    @Test func pullIngestsWebCookies() async throws {
        let h = try await Self.makeHarness()
        try await h.put(CookieNames.memberID, Self.memberID, domain: ".e-hentai.org")
        try await h.put(CookieNames.passHash, Self.passHash, domain: ".e-hentai.org")
        try await h.put(CookieNames.clearance, "clearance-fake-eh", domain: ".e-hentai.org")
        try await h.put("ipb_session_id", "session-fake-0001", domain: "forums.e-hentai.org")
        try await h.put(CookieNames.clearance, "clearance-fake-ex", domain: ".exhentai.org")
        try await h.put(CookieNames.igneous, "igneous-fake-0002", domain: ".exhentai.org")
        try await h.put("nw", "1", domain: ".e-hentai.org")
        try await h.put("other", "other-fake-0003", domain: ".example.com")
        try await h.bridge.pull()
        #expect(await h.jar(.eh) == Self.identity.merging([
            CookieNames.clearance: "clearance-fake-eh", "ipb_session_id": "session-fake-0001",
        ]) { $1 })
        #expect(await h.jar(.ex) == [CookieNames.clearance: "clearance-fake-ex", CookieNames.igneous: "igneous-fake-0002"])
        #expect(await h.store.memberID == 1_234_567)
        #expect(await h.userAgents.current == Self.webKitUserAgent)
        #expect(await h.userAgents.isWebKit)
    }

    @Test func pullSkipsClearanceWithoutAWebKitUserAgent() async throws {
        let h = try await Self.makeHarness(webKit: false)
        #expect(await !h.userAgents.isWebKit)
        try await h.put(CookieNames.memberID, Self.memberID, domain: ".e-hentai.org")
        try await h.put(CookieNames.clearance, "clearance-fake-eh", domain: ".e-hentai.org")
        try await h.put("cf_duid", "duid-fake-eh", domain: ".e-hentai.org")
        try await h.put(CookieNames.clearance, "clearance-fake-ex", domain: ".exhentai.org")
        try await h.put(CookieNames.igneous, "igneous-fake-0002", domain: ".exhentai.org")
        try await h.bridge.pull()
        #expect(await h.jar(.eh) == [CookieNames.memberID: Self.memberID])
        #expect(await h.jar(.ex) == [CookieNames.igneous: "igneous-fake-0002"])
        // The WebView keeps its own.
        #expect(await h.webCookies()[".e-hentai.org \(CookieNames.clearance)"] == "clearance-fake-eh")
    }

    @Test func pullSkipsEveryUserAgentBoundCloudflareCookieWithoutAWebKitUserAgent() async throws {
        let h = try await Self.makeHarness(webKit: false)
        try await h.put(CookieNames.memberID, Self.memberID, domain: ".e-hentai.org")
        for (name, value) in ["__cf_bm": "bm-fake-0001", "_cfuvid": "uvid-fake-0002", "cf_chl_prog": "chl-fake-0003"] {
            try await h.put(name, value, domain: ".e-hentai.org")
        }
        try await h.put("sk", "sk-fake-0004", domain: ".e-hentai.org")
        try await h.bridge.pull()
        #expect(await h.jar(.eh) == [CookieNames.memberID: Self.memberID, "sk": "sk-fake-0004"])
        #expect(await h.webCookies()[".e-hentai.org __cf_bm"] == "bm-fake-0001")

        // With a WebKit UA they are the WebView's own and are taken, like cf_clearance.
        let webKit = try await Self.makeHarness()
        try await webKit.put(CookieNames.memberID, Self.memberID, domain: ".e-hentai.org")
        try await webKit.put("__cf_bm", "bm-fake-0001", domain: ".e-hentai.org")
        try await webKit.bridge.pull()
        #expect(await webKit.jar(.eh)["__cf_bm"] == "bm-fake-0001")
    }

    /// A pull for a member who is no longer signed in (logged out, or another account) writes nothing.
    @Test func pullKeepsTheStoreForAnotherMember() async throws {
        let h = try await Self.makeHarness(eh: Self.identity)
        try await h.put(CookieNames.memberID, "7654321", domain: ".e-hentai.org")
        try await h.put("sk", "sk-fake-0001", domain: ".e-hentai.org")
        try await h.bridge.pull(expectedMemberID: 7_654_321)
        #expect(await h.jar(.eh) == Self.identity)

        try await h.put(CookieNames.memberID, Self.memberID, domain: ".e-hentai.org")
        try await h.bridge.pull(expectedMemberID: 1_234_567)
        #expect(await h.jar(.eh) == Self.identity.merging(["sk": "sk-fake-0001"]) { $1 })

        try await h.store.reset()
        try await h.bridge.pull(expectedMemberID: 1_234_567)
        #expect(await h.store.snapshot() == .empty)
    }

    /// Signed in as B and pushed: an earlier account's host-only ipb_member_id the push could not replace, or the
    /// forum's ipb_member_id=0, makes the pull write nothing (jar and vault as they were).
    @Test func pullRefusesAnotherIdentityInTheWebView() async throws {
        for (name, value, domain) in [
            (CookieNames.memberID, "7654321", "forums.e-hentai.org"), (CookieNames.memberID, "0", ".e-hentai.org"),
        ] {
            let h = try await Self.makeHarness(eh: Self.identity, ex: Self.identity)
            try await h.bridge.push()
            try await h.put(name, value, domain: domain)
            try await h.put("sk", "sk-fake-0001", domain: ".e-hentai.org")
            let before = await h.store.snapshot()
            let bytes = try h.vault.read()
            try await h.bridge.pull(expectedMemberID: 1_234_567)
            #expect(await h.store.snapshot() == before, "\(domain)")
            #expect(try h.vault.read() == bytes, "\(domain)")
            #expect(await h.store.memberID == 1_234_567)
        }
    }

    /// What changed in the jar after the push is not put back to the pushed value: a WebView cookie
    /// that still holds what was pushed for its site and name is left out; what the page set or changed is written.
    @Test func pullLeavesWhatThePushPutInUnlessThePageChangedIt() async throws {
        let h = try await Self.makeHarness(
            eh: Self.identity.merging(["sk": "sk-old-fake-0001", "hath_perks": "perks-old-fake-0002"]) { $1 },
            ex: Self.identity.merging([CookieNames.igneous: "igneous-old-fake-0003"]) { $1 }
        )
        let pushed = try await h.bridge.push()
        #expect(pushed.jars[.eh]?["sk"] == "sk-old-fake-0001")
        // A response elsewhere changes sk and igneous in the jar meanwhile.
        try await h.store.set(["sk": "sk-new-fake-0004"], for: [.eh])
        try await h.store.set([CookieNames.igneous: "igneous-new-fake-0005"], for: [.ex])
        // The page sets a session cookie and changes hath_perks.
        try await h.put("ipb_session_id", "session-fake-0006", domain: "forums.e-hentai.org")
        try await h.put("hath_perks", "perks-page-fake-0007", domain: ".e-hentai.org")

        try await h.bridge.pull(expectedMemberID: 1_234_567, unchangedSince: pushed)
        #expect(await h.jar(.eh) == Self.identity.merging([
            "sk": "sk-new-fake-0004", "hath_perks": "perks-page-fake-0007", "ipb_session_id": "session-fake-0006",
        ]) { $1 })
        #expect(await h.jar(.ex) == Self.identity.merging([CookieNames.igneous: "igneous-new-fake-0005"]) { $1 })

        // Without the record, every WebView cookie is taken, the pushed ones too.
        try await h.bridge.pull(expectedMemberID: 1_234_567)
        #expect(await h.jar(.eh)["sk"] == "sk-old-fake-0001")
        // Nothing shows a value.
        let text = String(describing: pushed) + String(reflecting: pushed)
        let showsValue = text.contains("fake")
        #expect(!showsValue)
    }

    /// Off the main actor too, nothing of `Pushed` shows a value: the app target's default
    /// isolation is the main actor, and a main-actor conformance to `CustomStringConvertible` or `CustomReflectable`
    /// does not hold elsewhere, where printing falls back to plain reflection of `jars`. A detached task runs off it.
    ///
    /// Through an unconstrained generic, as a log call taking any value would: the conformances are then looked up at
    /// run time. (Called on `Pushed` directly, off the main actor, a main-actor conformance does not even compile.)
    @Test func pushedShowsNoValueOffTheMainActor() async throws {
        let h = try await Self.makeHarness(eh: Self.identity.merging(["sk": "sk-fake-0001"]) { $1 })
        let pushed = try await h.bridge.push()
        let texts = await Task.detached { Self.texts(of: pushed) }.value
        let showsValue = texts.contains { text in
            text.contains("fake") || text.contains(Self.memberID) || text.contains(Self.passHash)
        }
        #expect(!showsValue)
        let describesCounts = texts.first == "Pushed(eh: 3, ex: 0)"
        #expect(describesCounts)
    }

    /// `String(describing:)`, `String(reflecting:)` and `dump` of `value`, whatever its type.
    nonisolated private static func texts<Value>(of value: Value) -> [String] {
        var dumped = ""
        dump(value, to: &dumped)
        return [String(describing: value), String(reflecting: value), dumped]
    }

    /// `epoch`: a pull for a cookie store session that has ended writes nothing.
    @Test func pullForAnEndedSessionWritesNothing() async throws {
        let h = try await Self.makeHarness(eh: Self.identity)
        let epoch = await h.store.epoch
        try await h.put("sk", "sk-fake-0001", domain: ".e-hentai.org")
        try await h.store.reset()
        try await h.store.set(Self.identity, for: [.eh])
        try await h.bridge.pull(expectedMemberID: 1_234_567, epoch: epoch)
        #expect(await h.jar(.eh) == Self.identity)
        try await h.bridge.pull(expectedMemberID: 1_234_567, epoch: await h.store.epoch)
        #expect(await h.jar(.eh)["sk"] == "sk-fake-0001")
    }

    // MARK: - Clear

    @Test func clearRemovesOnlySiteCookies() async throws {
        let h = try await Self.makeHarness(eh: Self.identity, ex: Self.identity)
        try await h.bridge.push()
        try await h.put("ipb_session_id", "session-fake-0001", domain: "forums.e-hentai.org")
        try await h.put(CookieNames.clearance, "clearance-fake-ex", domain: ".exhentai.org")
        try await h.put("other", "other-fake-0002", domain: ".example.com")
        try await h.put("host", "host-fake-0003", domain: "www.example.org")
        try await h.bridge.clear()
        #expect(await h.webCookies() == [".example.com other": "other-fake-0002", "www.example.org host": "host-fake-0003"])
        // The store is not touched.
        #expect(await h.jar(.eh) == Self.identity)
        #expect(await h.jar(.ex) == Self.identity)
    }

    /// Logging out: every kind of data, of every site, goes from the WebView store; the cookie store stays.
    @Test func removeAllDataLeavesNothing() async throws {
        let h = try await Self.makeHarness(eh: Self.identity, ex: Self.identity)
        try await h.bridge.push()
        try await h.put(CookieNames.clearance, "clearance-fake-0001", domain: "challenges.cloudflare.com")
        try await h.put("other", "other-fake-0002", domain: ".example.com")
        try await h.bridge.removeAllData()
        #expect(await h.webCookies().isEmpty)
        #expect(await h.bridge.dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()).isEmpty)
        #expect(await h.jar(.eh) == Self.identity)
        #expect(await h.jar(.ex) == Self.identity)
    }

    // MARK: - Time limits and order (M2 review, topic 3)

    /// Every operation on a WebKit store that does not answer ends with `WebStoreTimeout` within its time, the
    /// operations queued behind the one that hangs included; the cookie store is not touched.
    @Test(.timeLimit(.minutes(1))) func aStoreThatHangsEndsEveryOperationInTime() async throws {
        let webStore = ControlledWebStore(holding: [.allCookies, .setCookies, .removeAllData])
        defer { webStore.release() }
        let limit = Duration.milliseconds(300)
        let h = try await Self.makeHarness(eh: Self.identity, webStore: webStore, storeTimeout: limit)
        let operations: [(String, @MainActor () async throws -> Void)] = [
            ("push", { try await h.bridge.push() }),
            ("siteCookies", { _ = try await h.bridge.siteCookies() }),
            ("clear", { try await h.bridge.clear() }),
            ("pull", { try await h.bridge.pull() }),
            ("removeAllData", { try await h.bridge.removeAllData() }),
            ("consistency", { _ = try await h.bridge.consistency(webUserAgent: Self.webKitUserAgent) }),
        ]
        for (name, operation) in operations {
            let started = ContinuousClock.now
            await #expect(throws: WebStoreTimeout.self, Comment(rawValue: name)) { try await operation() }
            #expect(ContinuousClock.now - started < limit + .seconds(2), Comment(rawValue: name))
        }
        #expect(await h.jar(.eh) == Self.identity)
    }

    /// A caller that gives up gets `CancellationError` at once, while the store still hangs.
    @Test(.timeLimit(.minutes(1))) func aCancelledCallerDoesNotWaitForTheStore() async throws {
        let webStore = ControlledWebStore(holding: [.allCookies])
        defer { webStore.release() }
        let h = try await Self.makeHarness(webStore: webStore, storeTimeout: .seconds(30))
        let bridge = h.bridge
        let clear = Task { try await bridge.clear() }
        #expect(await eventually { webStore.isHolding(.allCookies) })
        let cancelled = ContinuousClock.now
        clear.cancel()
        await #expect(throws: CancellationError.self) { try await clear.value }
        #expect(ContinuousClock.now - cancelled < .seconds(2))
    }

    /// A clear that ran out of time and finishes late runs before the push that came after it, not over it: the
    /// push's cookies stay. One call at a time reaches the store: the clear's, then the push's.
    @Test(.timeLimit(.minutes(1))) func aLateClearDoesNotRunOverTheNextPush() async throws {
        let webStore = ControlledWebStore(holding: [.allCookies])
        defer { webStore.release() }
        let h = try await Self.makeHarness(eh: Self.identity, webStore: webStore, storeTimeout: .seconds(2))
        // An earlier account's identity, for the clear to delete.
        try await h.put(CookieNames.memberID, "7654321", domain: ".e-hentai.org")
        await #expect(throws: WebStoreTimeout.self) { try await h.bridge.clear() }
        #expect(webStore.isHolding(.allCookies))

        // The push's own calls are real: the roomy time, which a busy host needs.
        h.bridge.storeTimeout = WebSessionBridge.roomyTestTimeout
        let bridge = h.bridge
        let push = Task { try await bridge.push() }
        webStore.release()
        _ = try await push.value
        #expect(await h.webCookies()[".e-hentai.org \(CookieNames.memberID)"] == Self.memberID)
        #expect(webStore.events == [
            "begin allCookies", "end allCookies", "begin deleteCookie", "end deleteCookie",
            "begin setCookies", "end setCookies",
        ])
    }

    /// A removal (logging out) whose caller gave up before its turn came still runs, in its turn: a push that hung
    /// and ends late does not leave the account's cookies in the WebView store.
    @Test(.timeLimit(.minutes(1))) func aRemovalGivenUpStillRunsInTurn() async throws {
        let webStore = ControlledWebStore(holding: [.setCookies])
        defer { webStore.release() }
        let h = try await Self.makeHarness(eh: Self.identity, webStore: webStore, storeTimeout: .milliseconds(300))
        await #expect(throws: WebStoreTimeout.self) { try await h.bridge.push() }
        await #expect(throws: WebStoreTimeout.self) { try await h.bridge.removeAllData() }
        webStore.release()
        #expect(await eventually { webStore.events.last == "end removeAllData" })
        #expect(webStore.events == ["begin setCookies", "end setCookies", "begin removeAllData", "end removeAllData"])
        #expect(await h.webCookies().isEmpty)
    }

    /// An operation whose caller gave up before its turn came (the store still busy with the one before) does not
    /// run at all.
    @Test(.timeLimit(.minutes(1))) func anOperationGivenUpBeforeItsTurnDoesNotRun() async throws {
        let webStore = ControlledWebStore(holding: [.allCookies])
        defer { webStore.release() }
        let h = try await Self.makeHarness(eh: Self.identity, webStore: webStore, storeTimeout: .seconds(30))
        let bridge = h.bridge
        let clear = Task { try await bridge.clear() }
        #expect(await eventually { webStore.isHolding(.allCookies) })
        let push = Task { try await bridge.push() }
        try await Task.sleep(for: .milliseconds(200))
        push.cancel()
        await #expect(throws: CancellationError.self) { try await push.value }

        webStore.release()
        try await clear.value
        // The next operation runs once the clear is done, and the push never did.
        _ = try await h.bridge.siteCookies()
        #expect(webStore.calls == [.allCookies, .allCookies])
        #expect(await h.webCookies().isEmpty)
    }

    // MARK: - Consistency

    @Test func consistencyHoldsAfterPush() async throws {
        let h = try await Self.makeHarness(
            eh: Self.identity.merging(["sk": "sk-fake-0001", CookieNames.clearance: "clearance-fake-0002"]) { $1 },
            ex: Self.identity.merging([CookieNames.igneous: "igneous-fake-0003"]) { $1 }
        )
        let before = try await h.bridge.consistency(webUserAgent: Self.webKitUserAgent)
        // Names only, once each, whichever site misses them.
        #expect(before.missingInWebView == [CookieNames.igneous, CookieNames.memberID, CookieNames.passHash, "sk"])

        try await h.bridge.push()
        let after = try await h.bridge.consistency(webUserAgent: Self.webKitUserAgent)
        #expect(after.missingInWebView.isEmpty)
        #expect(after.missingInStore.isEmpty)
        #expect(after.differingValues.isEmpty)
        #expect(after.userAgentMatches)

        let otherAgent = try await h.bridge.consistency(webUserAgent: "FakeOther/1")
        #expect(!otherAgent.userAgentMatches)
    }
}
