import EHModels
import EHNetwork
import EHParsing
import Foundation

/// Why a list could not show a page, as the list words it (the failure view and the refresh banner of browse B4).
nonisolated enum ListFailure: Equatable {
    /// The site wants a signed-in session (`ParseError.loginRequired`).
    case loginRequired
    /// Both sites are paused by the breaker (`EHNetworkError.paused`): the request was not sent.
    case paused(SitePause)
    /// The site's notice instead of the page (`EHNetworkError.issue`).
    case siteIssue(ResponseIssue)
    /// The page is not in the Compact view and the user declined to switch.
    case compactDeclined
    /// The page was still not Compact after the switch.
    case compactUnavailable
    /// The server could not be reached, or answered with an error status.
    case network
    /// Anything else: the page could not be read.
    case unreadable
    /// The local favorites could not be read from the device (`LocalFavoritesUnavailable`): `canRetry` when a read of
    /// the store threw (Try Again may work), not when there is no store (it is opened once, at launch). Its own words
    /// will come with M8's error messages.
    case localFavoritesUnavailable(canRetry: Bool)

    /// The failure `error` means; nil for one that is dropped without a word: a cancellation (`CancellationError`,
    /// `EHNetworkError.cancelled`) and the page of an ended session (`EHNetworkError.sessionEnded`).
    init?(_ error: any Error) {
        switch error {
        case is CancellationError:
            return nil
        case let error as EHNetworkError:
            switch error {
            case .cancelled, .sessionEnded: return nil
            case .paused(let pause): self = .paused(pause)
            case .issue(let issue): self = .siteIssue(issue)
            case .transport, .httpStatus: self = .network
            }
        case let error as ParseError where error == .loginRequired:
            self = .loginRequired
        case let error as ListServiceError:
            switch error {
            case .displayModeNotCompact: self = .compactDeclined
            case .displayModeStillNotCompact: self = .compactUnavailable
            }
        case let error as LocalFavoritesUnavailable:
            self = .localFavoritesUnavailable(canRetry: error.canRetry)
        default:
            self = .unreadable
        }
    }

    var title: String {
        switch self {
        case .loginRequired: "Log In Again"
        case .paused(let pause): pause.reason == .banned ? "Temporarily Banned" : "Too Many Requests"
        case .siteIssue(.banned): "Temporarily Banned"
        case .siteIssue(.tooManyRequests): "Too Many Requests"
        case .siteIssue(.exAccessDenied): "ExHentai Unavailable"
        case .siteIssue: "Couldn't Load"
        case .compactDeclined, .compactUnavailable: "Compact View Needed"
        case .network: "Couldn't Load"
        case .unreadable: "Couldn't Read the Page"
        case .localFavoritesUnavailable: "Couldn't Load"
        }
    }

    /// The explanation; a pause's end is written as `expiryText(until:now:calendar:locale:)` gives it for now.
    var message: String {
        switch self {
        case .loginRequired:
            return "This list needs you to be logged in. Your session may have ended."
        case .paused(let pause):
            let until = Self.expiryText(until: pause.until, now: .now, calendar: .current, locale: .current)
            switch pause.reason {
            case .banned:
                return "Your IP address is temporarily banned. Requests to E-Hentai and ExHentai are paused until \(until)."
            case .tooManyRequests:
                return "Requests are paused until \(until), then resume on their own."
            }
        case .siteIssue(.banned(let remaining)):
            let banned = "Your IP address is temporarily banned."
            guard let remaining else { return banned }
            return banned + " The ban expires in about \(Self.remainingText(remaining, locale: .current))."
        case .siteIssue(.tooManyRequests):
            return "The site asked Eros-SE to slow down. Wait a minute and try again."
        case .siteIssue(.exAccessDenied):
            return "This account cannot open ExHentai."
        case .siteIssue:
            return "The site refused the request."
        case .compactDeclined:
            return "Eros-SE can only read the Compact list view."
        case .compactUnavailable:
            return "The site still shows another list view. Switch to Compact in the site's settings."
        case .network:
            return "Could not reach the server."
        case .unreadable:
            return "The page could not be read."
        case .localFavoritesUnavailable:
            return "Local favorites could not be loaded."
        }
    }

    /// The button the failure offers; nil when trying again cannot help (a ban, an account without ExHentai, local
    /// favorites without a store).
    var action: ListFailureAction? {
        switch self {
        case .loginRequired: .logIn
        case .paused(let pause): pause.reason == .banned ? nil : .tryAgain
        case .localFavoritesUnavailable(let canRetry): canRetry ? .tryAgain : nil
        case .siteIssue(.banned), .siteIssue(.exAccessDenied): nil
        case .siteIssue, .compactDeclined, .compactUnavailable, .network, .unreadable: .tryAgain
        }
    }

    /// When a pause ends: the time alone (`.shortened`) when that is on the day of `now` in `calendar`'s time zone,
    /// otherwise the date too (`.abbreviated`): a ban may last days.
    static func expiryText(until: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let sameDay = calendar.isDate(until, inSameDayAs: now)
        let style = Date.FormatStyle(
            date: sameDay ? .omitted : .abbreviated, time: .shortened, locale: locale, calendar: calendar,
            timeZone: calendar.timeZone
        )
        return until.formatted(style)
    }

    /// What is left of a ban, in hours and minutes ("2 hours, 1 minute"); less than a minute reads as one.
    static func remainingText(_ remaining: Duration, locale: Locale) -> String {
        max(remaining, .seconds(60)).formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(locale))
    }
}

/// What a failed list offers to do.
nonisolated enum ListFailureAction: Equatable {
    /// Open the login (the session ended).
    case logIn
    /// Ask again.
    case tryAgain
}

/// The text above a list's results.
nonisolated enum ListSummary {
    /// The site's summary without its bracketed links ("[Disable Filters]"), then, when it does not say so itself,
    /// how many galleries the account's filters hid from the page; nil when there is neither.
    static func text(resultSummary: String?, filteredCount: Int?) -> String? {
        var sentences: [String] = []
        if let resultSummary {
            let cleaned = resultSummary.replacing(/\[[^\]]*\]/, with: "")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !cleaned.isEmpty { sentences.append(cleaned) }
        }
        let saysFiltered = sentences.first?.contains(/Filtered [0-9,]+ galler/) ?? false
        if let filteredCount, filteredCount > 0, !saysFiltered {
            sentences.append(
                filteredCount == 1
                    ? "Filtered 1 gallery from this page." : "Filtered \(filteredCount) galleries from this page."
            )
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}
