import EHModels
import SwiftUI

/// The advanced options of a gallery search as `Form` sections (Flutter `_AdvanceView`, texts from
/// `extension.dart:521-537`), for a `Form` of the caller's: the group editor (browse B6) and search (Q3).
///
/// Only Show Galleries With Torrents and Show Expunged Galleries; Minimum Rating (a switch, then 2 to 5 stars, 2 when
/// turned on); Pages (a switch, then From and To: digits only, 0 or nothing for no bound, the field always showing the
/// bound the search holds, `pageInput(_:)`), with the caller's note under them if it gives one (`pagesNote`); Disable
/// Default Filters: Language, Uploader, Tags; Clear goes back to `AdvancedSearch()`. Each control is identified
/// `advanced.<name>` (search Q3 finds them so).
struct AdvancedSearchForm: View {
    /// A note in the footer of the Pages section, by the fields it is about, and its accessibility identifier.
    struct Note {
        let text: Text
        let identifier: String
    }

    @Binding private var search: AdvancedSearch
    private let pagesNote: Note?
    /// What the page fields show: always `pageText(_:)` of the bound the search holds (typing is turned into that at
    /// once, and so is any change of the search from elsewhere, Clear included).
    @State private var fromText: String
    @State private var toText: String

    /// `pagesNote`: shown under the Pages section while given (search Q3: that the bounds will be swapped).
    init(search: Binding<AdvancedSearch>, pagesNote: Note? = nil) {
        _search = search
        self.pagesNote = pagesNote
        let range = search.wrappedValue.pageRange
        _fromText = State(initialValue: Self.pageText(range?.from))
        _toText = State(initialValue: Self.pageText(range?.to))
    }

    var body: some View {
        Section {
            Toggle("Only Show Galleries With Torrents", isOn: $search.requireTorrent)
                .accessibilityIdentifier("advanced.torrents")
            Toggle("Show Expunged Galleries", isOn: $search.showExpunged)
                .accessibilityIdentifier("advanced.expunged")
        }
        Section {
            Toggle("Minimum Rating", isOn: minimumRatingIsOn)
                .accessibilityIdentifier("advanced.minimumRating")
            if search.minimumRating != nil {
                Picker("Minimum Rating", selection: minimumRating) {
                    ForEach(Self.ratings, id: \.self) { stars in
                        Text("\(stars) stars").tag(stars)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("advanced.minimumRatingValue")
            }
        }
        Section {
            Toggle("Pages", isOn: pagesAreOn)
                .accessibilityIdentifier("advanced.pages")
            if search.pageRange != nil {
                TextField("From", text: $fromText)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("advanced.pagesFrom")
                TextField("To", text: $toText)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("advanced.pagesTo")
            }
        } footer: {
            if let pagesNote {
                pagesNote.text
                    .accessibilityIdentifier(pagesNote.identifier)
            }
        }
        .onChange(of: fromText) { _, text in
            take(text, as: \.from, shown: $fromText)
        }
        .onChange(of: toText) { _, text in
            take(text, as: \.to, shown: $toText)
        }
        .onChange(of: search.pageRange) { _, range in
            // The search changed from elsewhere (Clear, the switch): the fields follow it.
            if fromText != Self.pageText(range?.from) { fromText = Self.pageText(range?.from) }
            if toText != Self.pageText(range?.to) { toText = Self.pageText(range?.to) }
        }
        Section("Disable Default Filters") {
            Toggle("Language", isOn: $search.disableLanguageFilter)
                .accessibilityIdentifier("advanced.disableLanguage")
            Toggle("Uploader", isOn: $search.disableUploaderFilter)
                .accessibilityIdentifier("advanced.disableUploader")
            Toggle("Tags", isOn: $search.disableTagFilter)
                .accessibilityIdentifier("advanced.disableTags")
        }
        Section {
            Button("Clear") {
                search = AdvancedSearch()
            }
            .accessibilityIdentifier("advanced.clear")
        }
    }

    /// The ratings the site offers (`f_srdd`).
    private static let ratings = Array(2...5)

    /// The most digits a page bound keeps (`CustomGroup` reads 1 to 9).
    private static let pageBoundDigits = 9

    /// What a page field's typed `text` becomes: its ASCII digits without leading zeros, at most `pageBoundDigits`,
    /// and the bound they give; nothing (and no bound) for no digits or only zeros.
    static func pageInput(_ text: String) -> PageBoundInput {
        let digits = text.filter { $0.isASCII && $0.isNumber }.drop { $0 == "0" }.prefix(pageBoundDigits)
        let bound = Int(digits)
        return PageBoundInput(text: pageText(bound), bound: bound)
    }

    /// What a page field shows for `bound`: its digits, or nothing.
    static func pageText(_ bound: Int?) -> String {
        bound.map(String.init) ?? ""
    }

    /// Whether a minimum rating is set; turning it on sets 2 stars.
    private var minimumRatingIsOn: Binding<Bool> {
        let search = $search
        return Binding {
            search.wrappedValue.minimumRating != nil
        } set: { isOn in
            search.wrappedValue.minimumRating = isOn ? search.wrappedValue.minimumRating ?? 2 : nil
        }
    }

    /// The minimum rating while one is set.
    private var minimumRating: Binding<Int> {
        let search = $search
        return Binding {
            search.wrappedValue.minimumRating ?? 2
        } set: { stars in
            search.wrappedValue.minimumRating = stars
        }
    }

    /// Whether a page range is set; turning it on sets one with neither bound.
    private var pagesAreOn: Binding<Bool> {
        let search = $search
        return Binding {
            search.wrappedValue.pageRange != nil
        } set: { isOn in
            search.wrappedValue.pageRange = isOn ? search.wrappedValue.pageRange ?? PageRange(from: nil, to: nil) : nil
        }
    }

    /// A page field changed to `text`: a text that is not what it stands for (`pageInput(_:)`) is replaced in the
    /// field at once (the field changes again, and that change is taken); one that is goes into the page range.
    private func take(_ text: String, as bound: WritableKeyPath<PageRange, Int?>, shown: Binding<String>) {
        let input = Self.pageInput(text)
        guard input.text == text else {
            shown.wrappedValue = input.text
            return
        }
        if search.pageRange?[keyPath: bound] != input.bound {
            search.pageRange?[keyPath: bound] = input.bound
        }
    }
}

/// A page field's text as `AdvancedSearchForm.pageInput(_:)` reads it: what the field shows, and the bound it gives.
nonisolated struct PageBoundInput: Equatable {
    let text: String
    let bound: Int?
}
