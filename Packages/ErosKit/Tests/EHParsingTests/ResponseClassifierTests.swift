import EHFixtures
import EHParsing
import Foundation
import Testing

@Suite struct ResponseClassifierTests {
    private static let banNotice = "Your IP address has been temporarily banned for excessive pageloads which "
        + "indicates that you are using automated mirroring/harvesting software."

    @Test func classifiesConstructedErrorPages() throws {
        let banned = try Fixtures.data("constructed/eh/banned.txt")
        #expect(ResponseClassifier.issue(status: 200, body: banned, expectsJSON: false, host: "e-hentai.org")
            == .banned(remaining: .seconds(3587)))
        let tooMany = try Fixtures.data("constructed/eh/http-429.html")
        #expect(ResponseClassifier.issue(status: 429, body: tooMany, expectsJSON: false, host: "e-hentai.org")
            == .tooManyRequests)
        let mismatch = try Fixtures.data("constructed/eh/showpage-key-mismatch.json")
        #expect(ResponseClassifier.issue(status: 200, body: mismatch, expectsJSON: true, host: "e-hentai.org")
            == .keyMismatch)
        #expect(ResponseClassifier.issue(status: 509, body: Data(), expectsJSON: false, host: "e-hentai.org")
            == .bandwidthExceeded)
        // Only the API answer is a key mismatch: the same body on a page request is not.
        #expect(ResponseClassifier.issue(status: 200, body: mismatch, expectsJSON: false, host: "e-hentai.org") == nil)
    }

    @Test func emptyEXBodyIsAccessDenied() {
        #expect(ResponseClassifier.issue(status: 200, body: Data(), expectsJSON: false, host: "exhentai.org")
            == .exAccessDenied)
        #expect(ResponseClassifier.issue(status: 200, body: Data(), expectsJSON: false, host: "EXHENTAI.ORG")
            == .exAccessDenied)
        // Thumbnails and images on other hosts, the other site, API answers, other statuses.
        #expect(ResponseClassifier.issue(status: 200, body: Data(), expectsJSON: false, host: "s.exhentai.org") == nil)
        #expect(ResponseClassifier.issue(status: 200, body: Data(), expectsJSON: false, host: "e-hentai.org") == nil)
        #expect(ResponseClassifier.issue(status: 200, body: Data(), expectsJSON: false, host: nil) == nil)
        #expect(ResponseClassifier.issue(status: 200, body: Data(), expectsJSON: true, host: "exhentai.org") == nil)
        #expect(ResponseClassifier.issue(status: 302, body: Data(), expectsJSON: false, host: "exhentai.org") == nil)
    }

    /// A fully qualified host ends in a dot and names the same host.
    @Test func exHostWithTrailingDotsIsAccessDenied() {
        for host in ["exhentai.org.", "EXHENTAI.ORG..", "ExHentai.org."] {
            #expect(ResponseClassifier.issue(status: 200, body: Data(), expectsJSON: false, host: host)
                == .exAccessDenied, "\(host)")
        }
        for host in ["s.exhentai.org.", "e-hentai.org.", ".", "exhentai.org.x"] {
            #expect(ResponseClassifier.issue(status: 200, body: Data(), expectsJSON: false, host: host) == nil, "\(host)")
        }
    }

    /// Every captured response (`api/*.json` as API answers) is an ordinary one.
    @Test func capturedSamplesHaveNoIssue() throws {
        let entries = try Fixtures.manifest().entries.filter { $0.source == .captured }
        #expect(entries.count >= Fixtures.minimumCapturedFixtures.values.reduce(0, +))
        for entry in entries {
            let body = try Fixtures.data(entry.path)
            let expectsJSON = entry.path.contains("/api/") && entry.path.hasSuffix(".json")
            let host = entry.url.flatMap { URL(string: $0)?.host() }
            #expect(host != nil, "\(entry.path) has no URL host")
            let issue = ResponseClassifier.issue(
                status: entry.status ?? 200, body: body, expectsJSON: expectsJSON, host: host
            )
            #expect(issue == nil, "\(entry.path)")
        }
    }

    @Test func bannedWordInsideHTMLIsNotABan() {
        let page = Data("<html><body>banned</body></html>".utf8)
        #expect(ResponseClassifier.issue(status: 200, body: page, expectsJSON: false, host: "e-hentai.org") == nil)
        let upper = Data("<HTML><body>\(Self.banNotice)</body></HTML>".utf8)
        #expect(ResponseClassifier.issue(status: 200, body: upper, expectsJSON: false, host: "e-hentai.org") == nil)
    }

    @Test func bannedWordInsideJSONIsNotABan() {
        let json = Data(#"{"gmetadata":[{"title":"banned"}]}"#.utf8)
        #expect(ResponseClassifier.issue(status: 200, body: json, expectsJSON: true, host: "e-hentai.org") == nil)
        // An API call answered with the plain-text notice is still a ban.
        let notice = Data(Self.banNotice.utf8)
        #expect(ResponseClassifier.issue(status: 200, body: notice, expectsJSON: true, host: "e-hentai.org")
            == .banned(remaining: nil))
    }

    /// Only the notice's own sentences make a ban: the word "banned" in any other text or bytes
    /// (a tag, a title, a .torrent's file name) is none, and neither is a body that is not UTF-8 text.
    @Test func bannedWordAloneIsNotABan() {
        func issue(_ body: Data, json: Bool = false) -> ResponseIssue? {
            ResponseClassifier.issue(status: 200, body: body, expectsJSON: json, host: "e-hentai.org")
        }
        for text in ["This tag is banned", "Fake Gallery 1 (banned edition)", "BANNED", "Your IP address is banned."] {
            #expect(issue(Data(text.utf8)) == nil, "\(text)")
            #expect(issue(Data(text.utf8), json: true) == nil, "\(text)")
        }
        // A .torrent-like bencoded body: its file name holds the word, its pieces are binary.
        let pieces: [UInt8] = [0x00, 0xFF, 0xFE, 0x80, 0x81, 0xC0, 0xC1, 0xF5, 0x10, 0x20, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x01, 0x02, 0x03, 0x04]
        func torrent(name: String) -> Data {
            Data("d8:announce26:https://ehtracker.org/fake4:infod4:name\(name.utf8.count):\(name)12:piece lengthi16384e6:pieces20:".utf8)
                + Data(pieces) + Data("ee".utf8)
        }
        #expect(issue(torrent(name: "Fake banned gallery.zip")) == nil)
        // Not text at all, even when its bytes happen to hold the notice's sentences.
        let binaryNotice = torrent(name: "temporarily banned. The ban expires in 1 hour.zip")
        #expect(issue(binaryNotice) == nil)
        #expect(issue(binaryNotice, json: true) == nil)
        // Either sentence alone is the notice.
        #expect(issue(Data("Your IP address has been temporarily banned.".utf8)) == .banned(remaining: nil))
        #expect(issue(Data("Fake notice. The ban expires in 1 hour".utf8)) == .banned(remaining: .seconds(3600)))
    }

    @Test func banDurationsParse() {
        func issue(_ text: String) -> ResponseIssue? {
            ResponseClassifier.issue(status: 200, body: Data(text.utf8), expectsJSON: false, host: "e-hentai.org")
        }
        #expect(issue("\(Self.banNotice) The ban expires in 2 hours, 1 minutes and 5 seconds")
            == .banned(remaining: .seconds(7265)))
        #expect(issue("\(Self.banNotice) The ban expires in 1 day, 1 hour and 1 second.")
            == .banned(remaining: .seconds(90001)))
        #expect(issue("\(Self.banNotice) The ban expires in 47 seconds\n") == .banned(remaining: .seconds(47)))
        #expect(issue("\(Self.banNotice) The ban expires in a while") == .banned(remaining: nil))
        #expect(issue("\(Self.banNotice) The ban expires in 2 fortnights") == .banned(remaining: nil))
        #expect(issue("\(Self.banNotice) The ban expires in 99999999999999999999 seconds") == .banned(remaining: nil))
        #expect(issue(Self.banNotice) == .banned(remaining: nil))
    }
}
