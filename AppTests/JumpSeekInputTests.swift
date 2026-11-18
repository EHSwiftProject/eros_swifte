import EHNetwork
import Foundation
import Testing

@testable import Eros

/// The input rules of the Jump/Seek and Jump to Page sheets, and which jumps a list offers. "Today" is 2026-11-08 in a
/// Gregorian calendar on UTC; the cursors are made up.
@Suite struct JumpSeekInputTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-11-08, noon UTC.
    private static let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 12))!

    private static func position(
        _ text: String, galleryID: String = "", direction: ListJumpDirection = .next,
        navigation: ListNavigation = .none
    ) -> Result<ListPosition, JumpSeekError> {
        JumpSeekInput.position(
            text: text, galleryID: galleryID, direction: direction, navigation: navigation, today: today,
            calendar: calendar
        )
    }

    // MARK: - Jump/Seek

    @Test func offsetsBecomeJumps() {
        let cases = [
            ("3d", "3d"), ("2w", "2w"), ("6m", "6m"), ("1y", "1y"), ("12", "12"), (" 3D ", "3d"),
            // Not four digits alone: no date's shape.
            ("20240", "20240"), ("1000d", "1000d"),
        ]
        for (text, jump) in cases {
            #expect(Self.position(text) == .success(.offset(jump: jump, seek: nil, from: nil)), "\(text)")
        }
    }

    /// Four digits alone are a year (a seek), not a jump.
    @Test func datesBecomeSeeks() {
        for text in ["2024-01-31", "2024-01", "2024", "24-01-31"] {
            #expect(Self.position(text) == .success(.offset(jump: nil, seek: text, from: nil)), "\(text)")
        }
    }

    @Test func badInputSendsNothing() {
        #expect(Self.position("") == .failure(.empty))
        #expect(Self.position("   ") == .failure(.empty))
        for text in ["abc", "1x", "2024-13-01", "2024-02-30"] {
            #expect(Self.position(text) == .failure(.malformed), "\(text)")
        }
    }

    /// From 2007-03-20 (the site's earliest day) to today; a year or a month counts from its first day.
    @Test func datesStayInTheSitesRange() {
        #expect(Self.position("2007-03-19") == .failure(.beforeEarliest))
        #expect(Self.position("2007-03-20") == .success(.offset(jump: nil, seek: "2007-03-20", from: nil)))
        #expect(Self.position("2026-11-08") == .success(.offset(jump: nil, seek: "2026-11-08", from: nil)))
        #expect(Self.position("2026-11-09") == .failure(.afterToday))
        #expect(Self.position("2026-11") == .success(.offset(jump: nil, seek: "2026-11", from: nil)))
        #expect(Self.position("2026-12") == .failure(.afterToday))
        #expect(Self.position("07-03-19") == .failure(.beforeEarliest))
        // A year or a month counts from its first day, at both ends.
        for text in ["2026", "2026-11", "26-11"] {
            #expect(Self.position(text) == .success(.offset(jump: nil, seek: text, from: nil)), "\(text)")
        }
        #expect(Self.position("2027") == .failure(.afterToday))
        #expect(Self.position("1000") == .failure(.beforeEarliest))
        #expect(Self.position("2007") == .failure(.beforeEarliest))
    }

    @Test func cursorComesFromTheList() {
        let list = ListNavigation.cursor(next: "123", previous: "456")
        #expect(Self.position("3d", direction: .next, navigation: list)
            == .success(.offset(jump: "3d", seek: nil, from: .next("123"))))
        #expect(Self.position("3d", direction: .previous, navigation: list)
            == .success(.offset(jump: "3d", seek: nil, from: .previous("456"))))
        #expect(Self.position("3d", direction: .previous, navigation: .cursor(next: "123", previous: nil))
            == .success(.offset(jump: "3d", seek: nil, from: nil)))
    }

    @Test func galleryIDOverridesTheCursor() {
        let list = ListNavigation.cursor(next: "123", previous: "456")
        #expect(Self.position("3d", galleryID: "999", direction: .next, navigation: list)
            == .success(.offset(jump: "3d", seek: nil, from: .next("999"))))
        #expect(Self.position("3d", galleryID: " 999 ", direction: .previous, navigation: list)
            == .success(.offset(jump: "3d", seek: nil, from: .previous("999"))))
        #expect(Self.position("3d", galleryID: "12a", navigation: list) == .failure(.malformedGalleryID))
    }

    /// The footer lists every error, the text's first: a malformed gallery ID shows while the text is empty too. Go
    /// takes the first one.
    @Test func everyErrorIsReported() {
        func read(_ text: String, galleryID: String) -> JumpSeekReading {
            JumpSeekInput.read(
                text: text, galleryID: galleryID, direction: .next, navigation: .none, today: Self.today,
                calendar: Self.calendar
            )
        }
        #expect(read("", galleryID: "12a").errors == [.empty, .malformedGalleryID])
        #expect(read("", galleryID: "12a").position == .failure(.empty))
        #expect(read("3d", galleryID: "12a").errors == [.malformedGalleryID])
        #expect(read("3d", galleryID: "12a").position == .failure(.malformedGalleryID))
        #expect(read("abc", galleryID: "").errors == [.malformed])
        #expect(read("3d", galleryID: "").errors.isEmpty)
        #expect(read("3d", galleryID: "999").cursor == .success(.next("999")))
        #expect(read("3d", galleryID: "999").position == .success(.offset(jump: "3d", seek: nil, from: .next("999"))))
    }

    /// The date picker writes its day as `yyyy-MM-dd`, which reads back as a seek.
    @Test func pickedDatesReadAsSeeks() {
        let picked = Self.calendar.date(from: DateComponents(year: 2024, month: 1, day: 5, hour: 23))!
        let text = JumpSeekInput.seekText(for: picked, calendar: Self.calendar)
        #expect(text == "2024-01-05")
        #expect(Self.position(text) == .success(.offset(jump: nil, seek: text, from: nil)))
    }

    // MARK: - Jump to Page

    @Test func pageNumbersAreOneBased() {
        #expect(PageJumpInput.position(for: "1", pageCount: 3) == .page(0))
        #expect(PageJumpInput.position(for: "3", pageCount: 3) == .page(2))
        #expect(PageJumpInput.position(for: " 2 ", pageCount: 3) == .page(1))
        for text in ["0", "4", "x", "", "-1", "+1"] {
            #expect(PageJumpInput.position(for: text, pageCount: 3) == nil, "\(text)")
        }
    }

    // MARK: - What a list offers

    @Test func optionsFollowTheNavigation() {
        let numbered = ListJumpOptions(navigation: .numbered(index: 0, count: 3), isAfterJump: false)
        #expect(numbered.offersPageJump && !numbered.offersJumpSeek && !numbered.offersBackToFirst)
        // One page has nowhere to jump to.
        #expect(!ListJumpOptions(navigation: .numbered(index: 0, count: 1), isAfterJump: false).offersPageJump)

        let cursor = ListJumpOptions(navigation: .cursor(next: "1", previous: nil), isAfterJump: false)
        #expect(!cursor.offersPageJump && cursor.offersJumpSeek && !cursor.offersBackToFirst)

        let none = ListJumpOptions(navigation: .none, isAfterJump: false)
        #expect(!none.offersPageJump && !none.offersJumpSeek && !none.offersBackToFirst)

        #expect(ListJumpOptions(navigation: .cursor(next: nil, previous: "1"), isAfterJump: true).offersBackToFirst)
        #expect(ListJumpOptions(navigation: .none, isAfterJump: true).offersBackToFirst)
    }
}
