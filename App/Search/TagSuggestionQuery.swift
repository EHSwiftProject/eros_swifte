import EHModels
import Foundation
import Observation

/// The tag suggestions of one search field: asks for each text as it changes, keeps only the answer for the text the
/// field holds now, and reports the suggestion the user applies.
///
/// Every screen with a search field makes its own (browse B6's keyword sheet, search Q2's `SearchModel`), over
/// `environment.tagSuggestions`; `AppEnvironment` holds none. A screen calls `textDidChange(_:site:)` when the field
/// changes and `text = query.apply(suggestion, to: text)` when one is picked. The question in progress is cancelled
/// when the query goes.
@MainActor @Observable final class TagSuggestionQuery {
    /// The suggestions for the field's text; empty while there are none or the field is blank.
    private(set) var suggestions: [TagSuggestion] = []

    @ObservationIgnored private let service: TagSuggestionService
    @ObservationIgnored private let suggest: @MainActor (String, EHSite) async -> [TagSuggestion]
    /// The text and site last passed to `textDidChange(_:site:)`.
    @ObservationIgnored private var text = ""
    @ObservationIgnored private var site: EHSite?
    /// The question in progress. For tests only: screens must not await or cancel it.
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    /// The report of the last choice (`apply(_:to:)`). For tests only: screens must not await or cancel it.
    @ObservationIgnored private(set) var choiceReport: Task<Void, Never>?

    /// `suggest` answers each text; nil asks `service.suggestions(for:site:)` (tests pass one of their own).
    init(service: TagSuggestionService, suggest: (@MainActor (String, EHSite) async -> [TagSuggestion])? = nil) {
        self.service = service
        self.suggest = suggest ?? { text, site in await service.suggestions(for: text, site: site) }
    }

    isolated deinit {
        task?.cancel()
    }

    /// Asks for the suggestions of `text`, cancelling the question before. A blank text clears them at once. An answer
    /// is shown only when its task was not cancelled and the text and site are still the ones it was asked for.
    func textDidChange(_ text: String, site: EHSite) {
        task?.cancel()
        task = nil
        self.text = text
        self.site = site
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            suggestions = []
            return
        }
        task = Task { [weak self, suggest] in
            let answer = await suggest(text, site)
            guard let self, !Task.isCancelled, self.text == text, self.site == site else { return }
            suggestions = answer
        }
    }

    /// `text` with `suggestion` applied (`SearchText.applying(_:to:)`), at once; clears the suggestions.
    ///
    /// The choice is reported to `TagSuggestionService.didChoose(_:)` in a task of its own (`choiceReport`), which
    /// starts at once: the service decides before this returns whether the local table gave the suggestion, but
    /// marking it used waits while an import holds the table, and the field must not wait for that (nor have what is
    /// typed meanwhile overwritten).
    func apply(_ suggestion: TagSuggestion, to text: String) -> String {
        let applied = SearchText.applying(suggestion, to: text)
        clear()
        choiceReport = Task.immediate { [service] in await service.didChoose(suggestion) }
        return applied
    }

    /// Cancels the question in progress and clears the suggestions.
    func clear() {
        task?.cancel()
        task = nil
        suggestions = []
    }
}
