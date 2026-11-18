import EHModels
import Foundation

/// A response that is not the requested content but a notice from the site about the client.
public enum ResponseIssue: Sendable, Equatable {
    /// The IP address is temporarily banned; `remaining` is read from "The ban expires in …" (nil: not given, or
    /// not understood).
    case banned(remaining: Duration?)
    /// HTTP 429.
    case tooManyRequests
    /// HTTP 509: the image quota is used up.
    case bandwidthExceeded
    /// ExHentai answered a page request with an empty 200: the account has no access (no or stale `igneous`).
    case exAccessDenied
    /// `api.php` answered `{"error": "Key mismatch"}`: the showkey is stale or wrong.
    case keyMismatch
}

/// Recognizes the site's notices (bans, rate limits, ExHentai's empty page, a stale showkey) before a response is
/// parsed. A body is decoded as text only when its bytes hold a sentence of the ban notice; no body text is ever
/// returned.
public enum ResponseClassifier {
    /// 429 → tooManyRequests; 509 → bandwidthExceeded; an HTML page request (expectsJSON false) to the host
    /// "exhentai.org" (any case, trailing dots aside) with status 200 and an empty body → exAccessDenied (not
    /// thumbnails or images on other hosts); a body that is valid UTF-8 without "<html" (any case) and holds a sentence
    /// of the ban notice ("temporarily banned" or "The ban expires in", as the site writes them) → banned (remaining
    /// parsed from "The ban expires in …"), except when expectsJSON and the body is valid JSON (a title may contain the
    /// words); expectsJSON and a JSON object {"error": "Key mismatch"} → keyMismatch; otherwise nil. The word "banned"
    /// alone is no notice: a tag, a title or a file name in any other body (a .torrent, say) may hold it.
    public static func issue(status: Int, body: Data, expectsJSON: Bool, host: String?) -> ResponseIssue? {
        switch status {
        case 429: return .tooManyRequests
        case 509: return .bandwidthExceeded
        default: break
        }
        if !expectsJSON, status == 200, body.isEmpty, let host, isEXHost(host) {
            return .exAccessDenied
        }
        if expectsJSON, let json = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) {
            // A valid JSON answer is never a ban notice, whatever its strings say.
            if let object = json as? [String: Any], object["error"] as? String == keyMismatchMessage {
                return .keyMismatch
            }
            return nil
        }
        // Search the bytes first: most bodies (pages, images) hold neither sentence, and need no decoding. The notice
        // is plain text, so a body that is not UTF-8 (an image, a .torrent) is none.
        guard banSentences.contains(where: { body.range(of: Data($0.utf8)) != nil }),
              let text = String(validating: body, as: UTF8.self),
              text.range(of: "<html", options: .caseInsensitive) == nil else { return nil }
        return .banned(remaining: banRemaining(in: text))
    }

    /// Whether `host`, lowercased and without its trailing dots ("exhentai.org." is the same host), is ExHentai's.
    private static func isEXHost(_ host: String) -> Bool {
        var name = host.lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        return name == EHSite.ex.host
    }

    private static let keyMismatchMessage = "Key mismatch"
    private static let banExpiry = "The ban expires in "
    /// The ban notice's own sentences: "Your IP address has been temporarily banned for …" and "The ban expires in …".
    private static let banSentences = ["temporarily banned", "The ban expires in"]

    /// Seconds per unit of the ban notice, singular and plural.
    private static let unitSeconds: [String: Int] = [
        "day": 86_400, "days": 86_400, "hour": 3_600, "hours": 3_600, "minute": 60, "minutes": 60,
        "second": 1, "seconds": 1,
    ]

    /// The duration after "The ban expires in ", up to the end of the sentence: amounts with units ("2 hours,
    /// 1 minutes and 5 seconds"), joined by "," or " and ". nil when any part is not "<number> <unit>" or the total
    /// overflows.
    private static func banRemaining(in text: String) -> Duration? {
        guard let marker = text.range(of: banExpiry) else { return nil }
        var rest = text[marker.upperBound...]
        if let end = rest.firstIndex(where: { $0 == "." || $0 == "<" || $0.isNewline }) {
            rest = rest[..<end]
        }
        let parts = rest.replacingOccurrences(of: " and ", with: ",").split(separator: ",")
        guard !parts.isEmpty else { return nil }
        var total = 0
        for part in parts {
            let words = part.split(whereSeparator: \.isWhitespace)
            guard words.count == 2, let amount = Int(words[0]), amount >= 0,
                  let unit = unitSeconds[words[1].lowercased()] else { return nil }
            let (seconds, productOverflows) = amount.multipliedReportingOverflow(by: unit)
            let (sum, sumOverflows) = total.addingReportingOverflow(seconds)
            guard !productOverflows, !sumOverflows else { return nil }
            total = sum
        }
        return .seconds(total)
    }
}
