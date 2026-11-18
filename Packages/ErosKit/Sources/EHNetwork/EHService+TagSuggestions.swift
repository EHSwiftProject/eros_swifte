import EHModels
import EHParsing
import Foundation

extension EHService {
    /// The site's tag suggestions for `text` (`tagsuggest`), in the answer's order.
    ///
    /// `text` is trimmed (whitespace and line breaks); blank text gives `[]` without a request. Anything else is sent
    /// as it is, quotes and inner line breaks included (the JSON body escapes them), through the client like every
    /// request, so the throttle applies.
    /// - Throws: as `api(_:parse:)` (`EHNetworkError.sessionEnded` included), or `APIResponseParser.tagSuggestions`'
    ///   errors.
    public func tagSuggestions(_ text: String, site: EHSite) async throws -> [TagRef] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await api(EHAPI.tagsuggest(trimmed, site: site), parse: APIResponseParser.tagSuggestions)
    }
}
