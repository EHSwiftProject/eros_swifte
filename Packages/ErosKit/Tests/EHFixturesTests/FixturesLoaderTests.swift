import EHFixtures
import Foundation
import Testing

@Suite struct FixturesLoaderTests {
    @Test func manifestDecodes() throws {
        _ = try Fixtures.manifest()
    }

    @Test func missingFixtureThrowsNotFound() {
        #expect(throws: FixtureError.notFound("eh/nope.html")) {
            try Fixtures.data("eh/nope.html")
        }
    }

    @Test func directoryIsNotAFixture() {
        #expect(throws: FixtureError.notFound("eh")) {
            try Fixtures.data("eh")
        }
    }

    @Test func entryRoundTripsThroughJSON() throws {
        let json = """
        {"path":"eh/list/front.html","site":"eh","source":"captured","method":"GET",\
        "url":"https://e-hentai.org/","status":200,"contentType":"text/html; charset=UTF-8",\
        "setCookieNames":["sk"],"capturedAt":"2026-11-04T00:00:00Z"}
        """
        let entry = try JSONDecoder().decode(FixtureEntry.self, from: Data(json.utf8))
        #expect(entry.path == "eh/list/front.html")
        #expect(entry.source == .captured)
        #expect(entry.status == 200)
        #expect(entry.setCookieNames == ["sk"])
        #expect(entry.location == nil)
        let again = try JSONDecoder().decode(FixtureEntry.self, from: JSONEncoder().encode(entry))
        #expect(again == entry)
    }

    @Test func manifestMatchesFiles() throws {
        let entries = try Fixtures.manifest().entries
        let paths = entries.map(\.path)
        #expect(Set(paths).count == paths.count, "duplicate manifest paths")
        for entry in entries {
            #expect((try? Fixtures.data(entry.path)) != nil, "missing fixture file: \(entry.path)")
        }
        let captured = Set(entries.filter { $0.source == .captured }.map(\.path))
        for path in try FixtureFiles.captured() {
            #expect(captured.contains(path), "no captured manifest entry: \(path)")
        }
        for entry in entries where entry.source == .constructed {
            #expect(entry.path.hasPrefix("constructed/"), "constructed entry outside constructed/: \(entry.path)")
        }
    }
}
