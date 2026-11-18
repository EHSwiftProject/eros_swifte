import EHModels
import SwiftUI

/// What the search field offers below it (`.searchSuggestions`, search Q2; Flutter `search_page.dart`).
///
/// - Nothing while the field holds the text searched, so the results are not covered.
/// - With the field empty, the history: a `Search History` header with, while tags are shown translated, Show
///   Translations or Show Originals (`search.history.translate`), and Clear (`search.history.clear`, which asks first
///   in a system alert through the app's alerts, `confirmClear()`); then one row per entry (`search.history`, labelled
///   with the entry; its translation above it when the history is shown translated and it has one), which appends it
///   to the text, with Delete in its context menu.
/// - With text: Open Link first when it links to a gallery or an image page (`search.openLink`, the link below it),
///   which pushes that page onto the tab's stack; one row per tag suggestion (`TagSuggestionRow`), which puts it in
///   place of the word being typed; and last `Search “<text>”` (`search.submit`), which searches.
///
/// Every row is a borderless button over the whole row (`wholeRow()`): on iOS 27.2 selecting a row of
/// `.searchSuggestions` (what a plain button in it does, and a tap in the row outside its button) also submits the
/// field (`onSubmit(of: .search)`), which would search the text a suggestion just changed, half typed, and push a
/// link or search a second time.
struct SearchSuggestionsContent: View {
    @Environment(AppEnvironment.self) private var environment
    let model: SearchModel

    init(model: SearchModel) {
        self.model = model
    }

    var body: some View {
        let text = SearchText.normalized(model.text)
        if model.isShowingSubmittedText {
            EmptyView()
        } else if text.isEmpty {
            if !model.history.isEmpty {
                history
            }
        } else {
            if let link = model.linkTarget, link.opensAPage {
                openLinkRow(link, text: text)
            }
            ForEach(model.suggestions, id: \.self) { suggestion in
                Button {
                    model.apply(suggestion)
                } label: {
                    TagSuggestionRow(
                        suggestion: suggestion, showsTranslation: environment.settings.settings.showsTagTranslations
                    )
                    .foregroundStyle(Color.primary)
                    .wholeRow()
                }
                .buttonStyle(.borderless)
                .listRowInsets(EdgeInsets())
            }
            Button {
                let model = model
                let router = environment.router
                Task { await model.submit(opening: router) }
            } label: {
                Label("Search “\(text)”", systemImage: "magnifyingglass")
                    .wholeRow()
            }
            .buttonStyle(.borderless)
            .listRowInsets(EdgeInsets())
            .accessibilityIdentifier("search.submit")
        }
    }

    // MARK: - Link

    private func openLinkRow(_ link: EHLink, text: String) -> some View {
        Button {
            environment.router.push(AppRoute(link))
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open Link")
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } icon: {
                Image(systemName: "arrow.right.circle")
            }
            .wholeRow()
        }
        .buttonStyle(.borderless)
        .listRowInsets(EdgeInsets())
        .accessibilityIdentifier("search.openLink")
    }

    // MARK: - History

    private var history: some View {
        Section {
            ForEach(model.history, id: \.self) { entry in
                historyRow(entry)
            }
        } header: {
            HStack {
                Text("Search History")
                Spacer()
                if environment.settings.settings.showsTagTranslations {
                    let translates = environment.searchPreferences.preferences.translatesHistory
                    Button(translates ? "Show Originals" : "Show Translations", systemImage: "globe") {
                        let model = model
                        Task { await model.toggleHistoryTranslation() }
                    }
                    .accessibilityIdentifier("search.history.translate")
                }
                Button("Clear", systemImage: "trash") {
                    confirmClear()
                }
                .accessibilityIdentifier("search.history.clear")
            }
        }
    }

    /// Asks before the history goes: Clear (destructive) or Cancel, in the app's alerts (QK64, user decision
    /// 2026-11-17). The root's host shows it, so it stays when the suggestions go: at a regular width the search ends,
    /// and the suggestions with it, once the field loses its focus, which the alert takes. A confirmation dialog could
    /// only hang from the page (its control is in the suggestions), where it sat over the field and the first row.
    private func confirmClear() {
        let model = model
        environment.alerts.present(Self.clearAlert { Task { await model.clearHistory() } })
    }

    /// The id of Clear's question, the same for every one: a second tap before the first shows puts up no second
    /// question (`AlertCenter.present(_:)` leaves an id already queued alone).
    private static let clearAlertID = UUID()

    /// Clear's question: Clear (destructive), which runs `clear`, or Cancel.
    static func clearAlert(clear: @escaping @MainActor () -> Void) -> HostedAlert {
        HostedAlert(
            id: clearAlertID, title: "Clear search history?",
            actions: [.init("Clear", role: .destructive, perform: clear), .init("Cancel", role: .cancel)]
        )
    }

    private func historyRow(_ entry: SearchModel.HistoryEntry) -> some View {
        Button {
            model.useHistory(entry.text)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.translation ?? entry.text)
                if entry.translation != nil {
                    Text(entry.text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(Color.primary)
            .wholeRow()
        }
        .buttonStyle(.borderless)
        .listRowInsets(EdgeInsets())
        .accessibilityLabel(entry.text)
        .accessibilityValue(entry.translation ?? "")
        .accessibilityIdentifier("search.history")
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) {
                let model = model
                Task { await model.removeHistory(entry.text) }
            }
        }
    }
}

private extension View {
    /// A label over its whole row, taps included (see the type): the row's insets as its padding, at least the row's
    /// height, leading-aligned. Its button sets the row's insets to none (`listRowInsets(EdgeInsets())`).
    func wholeRow() -> some View {
        modifier(WholeRow())
    }
}

/// `View.wholeRow()`. The horizontal inset is the system's row inset (20); the vertical one grows with the text size
/// (Dynamic Type), as the row's own does, so a row's edge stays its own at the larger sizes.
private struct WholeRow: ViewModifier {
    @Environment(\.defaultMinListRowHeight) private var minimumHeight
    @ScaledMetric(relativeTo: .body) private var verticalInset: CGFloat = 11

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 20)
            .padding(.vertical, verticalInset)
            .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
            .contentShape(.rect)
    }
}

private extension EHLink {
    /// Whether the link is a page the search opens (a gallery, an image page) rather than one it searches.
    var opensAPage: Bool {
        switch self {
        case .gallery, .imagePage: true
        case .tag, .uploader, .search: false
        }
    }
}
