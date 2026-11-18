import EHModels
import EHNetwork
import EHParsing
import Foundation
import Testing

@testable import Eros

/// `ListFailure` (what a list says when a page fails) and `ListSummary` (the text above the results).
@Suite struct ListFailureTests {
    /// A Gregorian calendar in UTC: 1_800_000_000 is Friday 2027-01-15, 08:00.
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private static let english = Locale(identifier: "en_US")
    private static let eight = Date(timeIntervalSince1970: 1_800_000_000)

    /// `text` with the formatter's narrow and no-break spaces as plain ones.
    private static func plain(_ text: String) -> String {
        text.replacing("\u{202F}", with: " ").replacing("\u{00A0}", with: " ")
    }

    @Test func errorsMapToFailures() {
        let pause = SitePause(reason: .banned, until: Self.eight)
        let cases: [(any Error, ListFailure?)] = [
            (ParseError.loginRequired, .loginRequired),
            (EHNetworkError.paused(pause), .paused(pause)),
            (EHNetworkError.issue(.tooManyRequests), .siteIssue(.tooManyRequests)),
            (EHNetworkError.issue(.banned(remaining: .seconds(60))), .siteIssue(.banned(remaining: .seconds(60)))),
            (EHNetworkError.issue(.exAccessDenied), .siteIssue(.exAccessDenied)),
            (ListServiceError.displayModeNotCompact(.thumbnail), .compactDeclined),
            (ListServiceError.displayModeStillNotCompact(.thumbnail), .compactUnavailable),
            (EHNetworkError.transport(.timedOut), .network),
            (EHNetworkError.transport(.notConnectedToInternet), .network),
            (EHNetworkError.httpStatus(500), .network),
            (ParseError.missing("list page"), .unreadable),
            (ParseError.malformed("rating"), .unreadable),
            (ListParseError.notCompact(.thumbnail), .unreadable),
            (CocoaError(.fileReadCorruptFile), .unreadable),
            // Dropped without a word.
            (CancellationError(), nil),
            (EHNetworkError.cancelled, nil),
            (EHNetworkError.sessionEnded, nil),
        ]
        for (error, failure) in cases {
            #expect(ListFailure(error) == failure, Comment(rawValue: "\(error)"))
        }
    }

    /// The titles, messages and actions, as the plan words them (pauses: `pausesShowTheirExpiry`).
    @Test func textsFollowTheTable() {
        let cases: [(ListFailure, String, String, ListFailureAction?)] = [
            (.loginRequired, "Log In Again", "This list needs you to be logged in. Your session may have ended.", .logIn),
            (.siteIssue(.banned(remaining: nil)), "Temporarily Banned", "Your IP address is temporarily banned.", nil),
            (
                .siteIssue(.tooManyRequests), "Too Many Requests",
                "The site asked Eros-SE to slow down. Wait a minute and try again.", .tryAgain
            ),
            (.siteIssue(.exAccessDenied), "ExHentai Unavailable", "This account cannot open ExHentai.", nil),
            (.siteIssue(.bandwidthExceeded), "Couldn't Load", "The site refused the request.", .tryAgain),
            (.siteIssue(.keyMismatch), "Couldn't Load", "The site refused the request.", .tryAgain),
            (.compactDeclined, "Compact View Needed", "Eros-SE can only read the Compact list view.", .tryAgain),
            (
                .compactUnavailable, "Compact View Needed",
                "The site still shows another list view. Switch to Compact in the site's settings.", .tryAgain
            ),
            (.network, "Couldn't Load", "Could not reach the server.", .tryAgain),
            (.unreadable, "Couldn't Read the Page", "The page could not be read.", .tryAgain),
        ]
        for (failure, title, message, action) in cases {
            #expect(failure.title == title, Comment(rawValue: "\(failure)"))
            #expect(failure.message == message, Comment(rawValue: "\(failure)"))
            #expect(failure.action == action, Comment(rawValue: "\(failure)"))
        }
    }

    @Test func pausesShowTheirExpiry() {
        let until = Self.eight
        let expiry = ListFailure.expiryText(until: until, now: .now, calendar: .current, locale: .current)
        let tooMany = ListFailure.paused(SitePause(reason: .tooManyRequests, until: until))
        #expect(tooMany.title == "Too Many Requests")
        #expect(tooMany.message == "Requests are paused until \(expiry), then resume on their own.")
        #expect(tooMany.action == .tryAgain)
        let banned = ListFailure.paused(SitePause(reason: .banned, until: until))
        #expect(banned.title == "Temporarily Banned")
        #expect(
            banned.message
                == "Your IP address is temporarily banned. Requests to E-Hentai and ExHentai are paused until \(expiry)."
        )
        #expect(banned.action == nil)
    }

    /// On the day of `now` the time alone; on another day (a ban may last days) the date too.
    @Test func expiryShowsTheDateUnlessItIsToday() {
        let sameDay = ListFailure.expiryText(
            until: Self.eight, now: Self.eight.addingTimeInterval(-3_600), calendar: Self.utc, locale: Self.english
        )
        #expect(Self.plain(sameDay) == "8:00 AM")
        let later = ListFailure.expiryText(
            until: Self.eight.addingTimeInterval(2 * 86_400), now: Self.eight, calendar: Self.utc, locale: Self.english
        )
        #expect(Self.plain(later) == "Jan 17, 2027 at 8:00 AM")
        // Just after midnight, the evening before is another day.
        let tomorrow = ListFailure.expiryText(
            until: Self.eight.addingTimeInterval(-8 * 3_600 + 60), now: Self.eight.addingTimeInterval(-9 * 3_600),
            calendar: Self.utc, locale: Self.english
        )
        #expect(Self.plain(tomorrow) == "Jan 15, 2027 at 12:01 AM")
    }

    @Test func banLengthIsInHoursAndMinutes() {
        #expect(ListFailure.remainingText(.seconds(7_260), locale: Self.english) == "2 hours, 1 minute")
        #expect(ListFailure.remainingText(.seconds(90_000), locale: Self.english) == "25 hours")
        #expect(ListFailure.remainingText(.seconds(2_700), locale: Self.english) == "45 minutes")
        // Less than a minute left still reads as a minute.
        #expect(ListFailure.remainingText(.seconds(30), locale: Self.english) == "1 minute")
        let remaining = ListFailure.remainingText(.seconds(7_260), locale: .current)
        #expect(
            ListFailure.siteIssue(.banned(remaining: .seconds(7_260))).message
                == "Your IP address is temporarily banned. The ban expires in about \(remaining)."
        )
    }

    @Test func summaryDropsBracketedLinks() {
        let text = ListSummary.text(
            resultSummary: "Found 2,396,024 results. Filtered 1 galleries from this page. [Disable Filters]",
            filteredCount: 1
        )
        #expect(text == "Found 2,396,024 results. Filtered 1 galleries from this page.")
        #expect(ListSummary.text(resultSummary: "[Disable Filters]", filteredCount: nil) == nil)
    }

    @Test func filteredCountIsAddedWhenTheSummaryLacksIt() {
        #expect(
            ListSummary.text(resultSummary: "Found 3 results.", filteredCount: 2)
                == "Found 3 results. Filtered 2 galleries from this page."
        )
        #expect(ListSummary.text(resultSummary: nil, filteredCount: 1) == "Filtered 1 gallery from this page.")
        #expect(ListSummary.text(resultSummary: "Found 3 results.", filteredCount: nil) == "Found 3 results.")
        #expect(ListSummary.text(resultSummary: "Found 3 results.", filteredCount: 0) == "Found 3 results.")
        #expect(ListSummary.text(resultSummary: nil, filteredCount: nil) == nil)
    }
}
