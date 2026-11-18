import EHParsing
import Foundation
import Testing

/// Fixed Unix times: the results must not depend on the machine's time zone, locale or calendar.
@Suite struct EHDateTests {
    @Test func listTimestampsAreUTC() {
        #expect(EHDate.listTimestamp("2024-01-02 03:04") == Date(timeIntervalSince1970: 1_704_164_640))
        #expect(EHDate.listTimestamp(" 2024-01-02 03:04\n") == Date(timeIntervalSince1970: 1_704_164_640))
        #expect(EHDate.listTimestamp("2024-02-30 03:04") == nil)
        #expect(EHDate.listTimestamp("2024-01-02 24:00") == nil)
        #expect(EHDate.listTimestamp("2024-01-02T03:04") == nil)
        #expect(EHDate.listTimestamp("") == nil)
    }

    @Test func commentTimestampsAreUTC() {
        #expect(EHDate.commentTimestamp("29 June 2020, 05:41") == Date(timeIntervalSince1970: 1_593_409_260))
        #expect(EHDate.commentTimestamp("29 Jun 2020, 05:41") == nil)
        #expect(EHDate.commentTimestamp("29 June 2020 05:41") == nil)
        #expect(EHDate.commentTimestamp("") == nil)
    }

    /// Only the site's exact shape is read: a format change must not slip through as a wrong date.
    @Test(arguments: [
        "2024-01-02 03:04 extra", "2024-01-02 03:04 UTC", "2024-01-02 03:04Z", // trailing text
        "2024-01-02 03:04:05", // seconds
        "24-01-02 03:04", "12024-01-02 03:04", // two- and five-digit years
        "\u{FF12}\u{FF10}\u{FF12}\u{FF14}-01-02 03:04", "2024-01-02 03:\u{FF10}4", // full-width digits
        "2024-1-2 3:04", "2024-01-02 3:04 PM", "2024-01-02 03:04 PM", // single digits, 12-hour clock
    ])
    func listTimestampsOfOtherShapesAreNil(text: String) {
        #expect(EHDate.listTimestamp(text) == nil)
    }

    @Test(arguments: [
        "29 June 2020, 05:41 by:", "29 June 2020, 05:41 UTC", // trailing text
        "29 June 2020, 05:41:07", // seconds
        "29 June 20, 05:41", // two-digit year
        "\u{FF12}\u{FF19} June 2020, 05:41", "29 June 2020, \u{FF10}5:41", // full-width digits
        "29 June 2020, 5:41 PM", "29 June 2020, 05:41 PM", "9 June 2020, 05:41", // 12-hour clock, one-digit day
        "29 Junex 2020, 05:41", // not a month
    ])
    func commentTimestampsOfOtherShapesAreNil(text: String) {
        #expect(EHDate.commentTimestamp(text) == nil)
    }
}
