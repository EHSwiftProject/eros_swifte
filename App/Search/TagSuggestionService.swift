import EHModels
import EHNetwork
import EHStore
import Foundation

/// Suggests tags for the word being typed in a search (Flutter `SearchPageController._delayedSearch`): from the local
/// tag table when tag translations are shown and the table has been imported, else from the site's `tagsuggest`,
/// without translations.
///
/// Unlike Flutter, an empty table falls back to the site (Flutter has no suggestions in Chinese then), and a local
/// search that finds nothing gives no suggestions (Flutter keeps the previous ones). The table's interface is
/// synchronous inside its actor, so while an import holds it, local suggestions wait until the import ends.
@MainActor final class TagSuggestionService {
    /// The most suggestions the local table gives.
    static let localLimit = 200

    /// How long `suggestions(for:site:)` waits before it asks, so that quick typing, each change cancelling the call
    /// before, asks only for the last word.
    let debounce: Duration

    /// An answer, kept so that the same word is not asked for again (Flutter does not ask for the same text twice).
    private struct Answer {
        /// The word asked for, without an exclusion's "-".
        let word: String
        let site: EHSite
        /// The version of the table that answered; nil when the site did. A new import gives a new version, so an
        /// answer from before it is never given again.
        let tableVersion: String?
        let suggestions: [TagSuggestion]
    }

    private let service: EHService
    private let translations: TagTranslationStore?
    private let settings: AppSettingsStore
    /// The last answer given.
    private var lastAnswer: Answer?

    init(
        service: EHService, translations: TagTranslationStore?, settings: AppSettingsStore,
        debounce: Duration = .milliseconds(500)
    ) {
        self.service = service
        self.translations = translations
        self.settings = settings
        self.debounce = debounce
    }

    /// The suggestions for the word being typed in `text`: `SearchText.currentToken(in:)`, trimmed, without the "-"
    /// of an exclusion (`-fak` is asked as `fak`; `SearchText.applying(_:to:)` keeps the "-").
    ///
    /// The same word, site and source (the site, or the table at the same version) as the last answer give that
    /// answer again at once; the word is remembered without its "-", as the answer does not depend on it. Otherwise
    /// the call waits `debounce`, then searches the local table for `SearchText.localQuery(for:)` (at most
    /// `localLimit`, most recently used first, each tag once whatever its case, with its translated name) or sends the
    /// word to the site. Gives `[]` for an empty word or query, when the task is cancelled (while waiting or while the
    /// answer comes), and when the table or the site fails; such a call is not remembered.
    func suggestions(for text: String, site: EHSite) async -> [TagSuggestion] {
        var token = Substring(SearchText.currentToken(in: text).trimmingCharacters(in: .whitespacesAndNewlines))
        if token.hasPrefix("-") { token = token.dropFirst() }
        let word = String(token)
        guard !word.isEmpty else { return [] }
        let table = await localTable()
        if let lastAnswer, lastAnswer.word == word, lastAnswer.site == site,
           lastAnswer.tableVersion == table?.version {
            return lastAnswer.suggestions
        }
        do {
            try await Task.sleep(for: debounce)
        } catch {
            return []
        }
        let suggestions: [TagSuggestion]
        do {
            if let table {
                let query = SearchText.localQuery(for: word)
                guard !query.isEmpty else { return [] }
                let rows = try await table.store.search(query, limit: Self.localLimit)
                suggestions = Self.unique(rows.map { row in
                    TagSuggestion(
                        tag: TagRef(namespace: row.namespace, name: row.key),
                        translation: row.plainName.isEmpty ? nil : row.plainName
                    )
                })
            } else {
                suggestions = try await service.tagSuggestions(word, site: site).map {
                    TagSuggestion(tag: $0, translation: nil)
                }
            }
        } catch {
            return []
        }
        guard !Task.isCancelled else { return [] }
        lastAnswer = Answer(word: word, site: site, tableVersion: table?.version, suggestions: suggestions)
        return suggestions
    }

    /// Records that the user chose `suggestion`. When the local table gave it (the last answer came from the table and
    /// holds it), it is marked used, so that the table lists it first from now on, and that answer is forgotten, so
    /// that the same word asks the table again. A suggestion from the site changes nothing.
    func didChoose(_ suggestion: TagSuggestion) async {
        guard let translations, let lastAnswer, lastAnswer.tableVersion != nil,
              lastAnswer.suggestions.contains(suggestion) else { return }
        self.lastAnswer = nil
        try? await translations.markUsed(suggestion.tag)
    }

    /// The table and its version, when it answers: tag translations are shown and it has been imported (`version()`
    /// is not nil).
    private func localTable() async -> (store: TagTranslationStore, version: String)? {
        guard settings.settings.showsTagTranslations, let translations,
              let version = try? await translations.version() else { return nil }
        return (translations, version)
    }

    /// `suggestions` with each tag once, where it first appears. Tags that differ only in case (or in surrounding
    /// spaces) count as one, as the table looks tags up trimmed and lowercased (`translation(for:)`, `markUsed(_:)`).
    private static func unique(_ suggestions: [TagSuggestion]) -> [TagSuggestion] {
        var seen = Set<TagRef>()
        return suggestions.filter { suggestion in
            let tag = suggestion.tag
            return seen.insert(TagRef(namespace: tag.namespace.map(folded), name: folded(tag.name))).inserted
        }
    }

    private static func folded(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
