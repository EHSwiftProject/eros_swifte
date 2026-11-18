import Foundation

/// Timestamps as the site writes them, always read as UTC with the `en_US_POSIX` locale and the Gregorian calendar,
/// whatever the device's time zone, region, calendar or 12/24-hour setting.
public enum EHDate {
    /// "yyyy-MM-dd HH:mm" (list and detail pages), UTC: exactly that shape, every field with exactly that many ASCII
    /// digits. Surrounding whitespace is ignored; nil for anything else (seconds, trailing text, other digits),
    /// including dates that do not exist.
    public static func listTimestamp(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The strategy alone reads a prefix and takes other shapes (two-digit years, full-width digits), so the
        // whole text must have the site's shape first.
        guard trimmed.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}/) != nil else { return nil }
        return try? listStrategy.parse(trimmed)
    }

    /// "dd MMMM yyyy, HH:mm" (comments, e.g. "29 June 2020, 05:41"), UTC: exactly that shape, with ASCII digits, a
    /// two-digit day and the month spelled in full. Surrounding whitespace is ignored; nil for anything else
    /// (trailing text, "AM"/"PM", two-digit years, abbreviated months).
    public static func commentTimestamp(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.wholeMatch(of: /[0-9]{2} [A-Za-z]+ [0-9]{4}, [0-9]{2}:[0-9]{2}/) != nil else { return nil }
        return try? commentStrategy.parse(trimmed)
    }

    private static func strategy(_ format: Date.FormatString) -> Date.ParseStrategy {
        // Not lenient: "Jun" does not pass for "June", and impossible dates are rejected. The shape is checked by the
        // callers: the strategy does not reject trailing text.
        Date.ParseStrategy(
            format: format, locale: Locale(identifier: "en_US_POSIX"), timeZone: TimeZone(identifier: "UTC")!,
            calendar: Calendar(identifier: .gregorian), isLenient: false
        )
    }

    private static let listStrategy = strategy("""
        \(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \
        \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)
        """)

    private static let commentStrategy = strategy("""
        \(day: .twoDigits) \(month: .wide) \(year: .defaultDigits), \
        \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)
        """)
}
