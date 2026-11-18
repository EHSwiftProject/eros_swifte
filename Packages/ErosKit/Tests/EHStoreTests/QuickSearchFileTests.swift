import EHStore
import Foundation
import Testing

@Suite struct QuickSearchFileTests {
    @Test func exportStartsWithTheHeader() {
        #expect(
            QuickSearchFile.export(["l:\"fake language$\"", "other:\"fake tag$\""])
                == "#FEhViewer\nl:\"fake language$\"\nother:\"fake tag$\""
        )
        #expect(QuickSearchFile.export([]) == "#FEhViewer")
    }

    @Test func parseSkipsCommentsAndBlankLines() throws {
        let text = "#FEhViewer\nl:\"fake language$\"\n\n   \n#note\n  other:\"fake tag$\"  \r\n示例 検索 🔍\n"
        #expect(
            try QuickSearchFile.parse(text) == ["l:\"fake language$\"", "other:\"fake tag$\"", "示例 検索 🔍"]
        )
    }

    @Test func parseNeedsTheHeader() {
        #expect(throws: QuickSearchFileError.missingHeader) {
            try QuickSearchFile.parse("l:\"fake language$\"\no:\"fake other\"")
        }
    }

    @Test func byteOrderMarkIsIgnored() throws {
        #expect(try QuickSearchFile.parse("\u{FEFF}#FEhViewer\na") == ["a"])
    }

    @Test func exportThenParseRoundTrips() throws {
        let texts = ["l:\"fake language$\"", "示例 検索 🔍", "a  b"]
        #expect(try QuickSearchFile.parse(QuickSearchFile.export(texts)) == texts)
    }

    @Test func fileNameUsesLocalTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 5))!
        #expect(QuickSearchFile.fileName(at: date) == "QSearch_20260102_030405.txt")
    }
}
