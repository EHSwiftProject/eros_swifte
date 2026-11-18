import EHFixtures
import EHModels
import EHParsing
import Testing

/// Display mode detection on real captured front pages and on the constructed non-Compact copy.
@Suite struct ListDisplayModeFixtureTests {
    /// The capture tool only writes fixtures when the front page is Compact, so both sites' front pages must be.
    @Test(arguments: ["eh/list/front.html", "ex/list/front.html"])
    func capturedFrontPagesAreCompact(path: String) throws {
        #expect(try ListDisplayMode.detect(in: Fixtures.string(path)) == .compact)
    }

    /// `constructed/eh/list-non-compact.html` is `eh/list/front.html` with the selector moved to Thumbnail.
    @Test func constructedNonCompactIsThumbnail() throws {
        #expect(try ListDisplayMode.detect(in: Fixtures.string("constructed/eh/list-non-compact.html")) == .thumbnail)
    }
}
