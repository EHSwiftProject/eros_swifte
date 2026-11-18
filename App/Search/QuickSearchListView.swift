import EHStore
import SwiftUI
import UniformTypeIdentifiers

/// The quick search page (search Q4; Flutter `quick_search_page.dart`), identified `quickSearch.root`, titled
/// `Quick Search` (inline), pushed from the search page: one row a quick search (`quickSearch.row`, labelled with its
/// text), its translation below it while tags are shown translated. Tapping a row hands its text to `onSelect` (the
/// search page goes back and searches it); swiping deletes a row, and in edit mode the rows are deleted and reordered,
/// a tap on one doing nothing.
///
/// The toolbar has Add (`quickSearch.add`: `New Quick Search`, an alert with a field, which the page presents itself,
/// as the app's `AlertCenter` shows alerts of buttons only), the edit mode switch (`quickSearch.edit`, Edit then Done;
/// the system's `EditButton` has a title only, which the iPhone Duo's rail cannot show, as browse B6), and the Import
/// and Export menu (`quickSearch.menu`): Share, Export to Files, Import, and Remove All, which asks first in a system
/// alert through the app's alerts (QK64, user decision 2026-11-17: a menu item is gone with its menu, so a
/// confirmation dialog would have no control to come from and sat over the page's title and first row). An import
/// tells how many searches were new, or that the file is not a quick search file, through the app's alerts. Without a
/// store the page says so and its toolbar has the back button only. Both status pages keep clear of the Duo's fold
/// (`keepsClearOfFold(alignment:)`, D2).
struct QuickSearchListView: View {
    @Environment(AppEnvironment.self) private var environment
    private let model: QuickSearchListModel
    private let onSelect: (String) -> Void

    @State private var editMode: EditMode = .inactive
    /// Whether New Quick Search is up, and the text in its field.
    @State private var isAdding = false
    @State private var newText = ""
    @State private var isImporting = false
    @State private var isExporting = false
    /// The file name Export to Files offers, without its extension: the exporter adds the one of the content type.
    @State private var exportName = ""

    init(model: QuickSearchListModel, onSelect: @escaping (String) -> Void) {
        self.model = model
        self.onSelect = onSelect
    }

    var body: some View {
        content
            .environment(\.editMode, $editMode)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("quickSearch.root")
            .navigationTitle("Quick Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.isAvailable {
                    toolbarItems
                }
            }
            .alert("New Quick Search", isPresented: $isAdding) {
                TextField("Keywords", text: $newText)
                    // As the search field: the site's syntax needs straight quotes and tags as typed.
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("quickSearch.newText")
                Button("Add") {
                    let model = model
                    let text = newText
                    Task { _ = await model.add(text) }
                }
                .disabled(SearchText.normalized(newText).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.plainText]) { result in
                importFile(result)
            }
            .fileExporter(
                isPresented: $isExporting, item: QuickSearchExport(texts: model.items), contentTypes: [.plainText],
                defaultFilename: exportName
            ) { _ in }
            .task {
                await model.load()
            }
    }

    @ViewBuilder private var content: some View {
        if model.isAvailable {
            List {
                ForEach(model.items, id: \.self) { text in
                    row(text)
                }
                .onDelete { offsets in
                    Task.immediate { await model.remove(atOffsets: offsets) }
                }
                .onMove { offsets, destination in
                    Task.immediate { await model.move(fromOffsets: offsets, toOffset: destination) }
                }
            }
            .overlay {
                if model.items.isEmpty {
                    ContentUnavailableView(
                        "No Quick Searches", systemImage: "list.bullet",
                        description: Text("Save a search with “Add to Quick Search” on the search page.")
                    )
                    .keepsClearOfFold()
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("quickSearch.empty")
                }
            }
        } else {
            ContentUnavailableView(
                "Quick Searches Unavailable", systemImage: "exclamationmark.triangle",
                description: Text("Saved data could not be opened.")
            )
            .keepsClearOfFold()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("quickSearch.unavailable")
        }
    }

    /// The row of `text`: the text, and its translation below it when there is one. In edit mode its tap does nothing;
    /// it stays enabled, as `disabled` would grey the text. The page's own `editMode` is read: the environment value
    /// it sets reaches the views below the page only.
    private func row(_ text: String) -> some View {
        let translation = model.translations[text]
        return Button {
            guard !editMode.isEditing else { return }
            onSelect(text)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                if let translation {
                    Text(translation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .tint(.primary)
        .accessibilityIdentifier("quickSearch.row")
        .accessibilityLabel(text)
        .accessibilityValue(translation ?? "")
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarPinnedTrailing) {
            Button("Add", systemImage: "plus") {
                newText = ""
                isAdding = true
            }
            .accessibilityIdentifier("quickSearch.add")
        }
        ToolbarItem(placement: .primaryAction) {
            let isEditing = editMode.isEditing
            Button(isEditing ? "Done" : "Edit", systemImage: isEditing ? "checkmark" : "pencil") {
                withAnimation { editMode = isEditing ? .inactive : .active }
            }
            .accessibilityIdentifier("quickSearch.edit")
        }
        ToolbarItem(placement: .secondaryAction) {
            Menu {
                ShareLink("Share", item: QuickSearchExport(texts: model.items), preview: SharePreview("Quick Search"))
                    .accessibilityIdentifier("quickSearch.share")
                Button("Export to Files", systemImage: "folder") {
                    exportName = Self.exportBaseName(at: .now)
                    isExporting = true
                }
                .accessibilityIdentifier("quickSearch.export")
                Button("Import", systemImage: "square.and.arrow.down") {
                    isImporting = true
                }
                .accessibilityIdentifier("quickSearch.import")
                Button("Remove All", systemImage: "trash", role: .destructive) {
                    confirmRemoveAll()
                }
                .accessibilityIdentifier("quickSearch.removeAll")
            } label: {
                Label("Import and Export", systemImage: "arrow.up.arrow.down.circle")
            }
            .accessibilityIdentifier("quickSearch.menu")
        }
    }

    /// Asks before every quick search goes: Remove All (destructive) or Cancel, in the app's alerts.
    private func confirmRemoveAll() {
        let model = model
        environment.alerts.present(Self.removeAllAlert { Task { await model.removeAll() } })
    }

    /// The id of Remove All's question, the same for every one: a second tap before the first shows puts up no
    /// second question (`AlertCenter.present(_:)` leaves an id already queued alone).
    private static let removeAllAlertID = UUID()

    /// Remove All's question: Remove All (destructive), which runs `remove`, or Cancel.
    static func removeAllAlert(remove: @escaping @MainActor () -> Void) -> HostedAlert {
        HostedAlert(
            id: removeAllAlertID, title: "Remove all quick searches?",
            actions: [.init("Remove All", role: .destructive, perform: remove), .init("Cancel", role: .cancel)]
        )
    }

    /// Imports the file picked (`QuickSearchListModel.importFile(at:)`) and tells the result in the app's alerts:
    /// how many searches were new, or, for a file that could not be read, is not UTF-8 text or has no header, that it
    /// is not a quick search file. Nothing is told when the picking was cancelled.
    private func importFile(_ result: Result<URL, any Error>) {
        let alerts = environment.alerts
        let notAFile = HostedAlert(
            title: "Not a Quick Search File", message: "The file must start with #FEhViewer.",
            actions: [HostedAlert.Action("OK")]
        )
        let url: URL
        switch result {
        case .success(let picked):
            url = picked
        case .failure(let error):
            if (error as? CocoaError)?.code != .userCancelled { alerts.present(notAFile) }
            return
        }
        let model = model
        Task {
            do {
                let count = try await model.importFile(at: url)
                alerts.present(HostedAlert(
                    title: "Imported \(count) Quick Searches", actions: [HostedAlert.Action("OK")]
                ))
            } catch {
                alerts.present(notAFile)
            }
        }
    }

    /// `QuickSearchFile.fileName(at:)` without its ".txt".
    private static func exportBaseName(at date: Date) -> String {
        let name = QuickSearchFile.fileName(at: date)
        return name.hasSuffix(".txt") ? String(name.dropLast(".txt".count)) : name
    }
}
