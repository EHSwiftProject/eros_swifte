import EHStore
import Foundation
import Testing

@testable import Eros

/// `QuickSearchListModel` (search Q4) over an in-memory `UserDataStore`: the order, adding, removing and moving, the
/// import and the export, and the translations. Every text here is made up.
@MainActor @Suite struct QuickSearchListModelTests {
    struct Harness {
        let store: UserDataStore
        let settings: AppSettingsStore
        let terms: SearchTermTranslator

        /// A new model over the harness's store, settings and translator.
        @MainActor func model() -> QuickSearchListModel {
            QuickSearchListModel(userData: store, terms: terms, settings: settings)
        }
    }

    /// An empty in-memory store, settings of their own (tags not translated), and a translator over `translations`.
    static func makeHarness(translations: TagTranslationStore? = nil) throws -> Harness {
        Harness(
            store: try UserDataStore(inMemory: true),
            settings: AppSettingsStore(ownedSuiteNamed: "proj.eros.swifte.tests.quickSearch.\(UUID().uuidString)"),
            terms: SearchTermTranslator(translations: translations)
        )
    }

    /// A new file in the temporary directory holding `data`; the caller removes it.
    static func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "quick-search-test-\(UUID().uuidString).txt")
        try data.write(to: url)
        return url
    }

    @Test func loadKeepsTheStoredOrder() async throws {
        let h = try Self.makeHarness()
        for text in ["fake b", "fake a", "fake c"] {
            #expect(try await h.store.addQuickSearch(text))
        }
        let model = h.model()
        #expect(model.isAvailable)
        await model.load()
        #expect(model.items == ["fake b", "fake a", "fake c"])
    }

    /// Every line break, U+2028 among them, becomes a space, so the text stays one line of
    /// the export.
    @Test func addingTextWithALineBreakKeepsOneLine() async throws {
        for text in ["a\nb", "a\u{2028}b"] {
            let h = try Self.makeHarness()
            let model = h.model()
            await model.load()
            #expect(await model.add(text))
            #expect(model.items == ["a b"])
            #expect(try await h.store.quickSearches() == ["a b"])
            #expect(model.exportText() == "#FEhViewer\na b")
        }
    }

    @Test func duplicatesAndBlanksAreIgnored() async throws {
        let h = try Self.makeHarness()
        let model = h.model()
        await model.load()
        #expect(await model.add("a"))
        #expect(await model.add(" a ") == false)
        #expect(await model.add("  ") == false)
        #expect(await model.add("\n\t") == false)
        #expect(model.items == ["a"])
        #expect(try await h.store.quickSearches() == ["a"])
    }

    /// The store only removes by text: the texts at the offsets go one by one, and every one
    /// for Remove All; another model over the store reads the same.
    @Test func removeAndMovePersist() async throws {
        let h = try Self.makeHarness()
        let model = h.model()
        await model.load()
        for text in ["fake a", "fake b", "fake c", "fake d"] {
            #expect(await model.add(text))
        }

        await model.move(fromOffsets: [2], toOffset: 0)
        #expect(model.items == ["fake c", "fake a", "fake b", "fake d"])
        await model.remove(atOffsets: [1, 3])
        #expect(model.items == ["fake c", "fake b"])

        let reread = h.model()
        await reread.load()
        #expect(reread.items == ["fake c", "fake b"])

        await reread.removeAll()
        #expect(reread.items.isEmpty)
        #expect(try await h.store.quickSearches().isEmpty)
    }

    /// `#` lines and blank lines are skipped; a search already there is not counted; each line is normalized (a tab
    /// becomes a space).
    @Test func importMergesAndCountsNewOnes() async throws {
        let h = try Self.makeHarness()
        #expect(try await h.store.addQuickSearch("a"))
        let model = h.model()
        await model.load()

        let file = try Self.temporaryFile(Data("#FEhViewer\nx\n# note\n\ny\na".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try await model.importFile(at: file) == 2)
        #expect(model.items == ["a", "x", "y"])

        let second = try Self.temporaryFile(Data("#FEhViewer\r\nfake\ttab\r\nx\r\n".utf8))
        defer { try? FileManager.default.removeItem(at: second) }
        #expect(try await model.importFile(at: second) == 1)
        #expect(model.items == ["a", "x", "y", "fake tab"])
    }

    /// A file without the header, one that is not UTF-8 and one that cannot be read all
    /// throw, and change nothing.
    @Test func importWithoutHeaderThrows() async throws {
        let h = try Self.makeHarness()
        #expect(try await h.store.addQuickSearch("a"))
        let model = h.model()
        await model.load()

        let headless = try Self.temporaryFile(Data("x\ny\n".utf8))
        defer { try? FileManager.default.removeItem(at: headless) }
        await #expect(throws: QuickSearchFileError.missingHeader) {
            try await model.importFile(at: headless)
        }

        let notUTF8 = try Self.temporaryFile(Data([0x23, 0xC3, 0x28, 0x0A, 0x78]))
        defer { try? FileManager.default.removeItem(at: notUTF8) }
        await #expect(throws: (any Error).self) {
            try await model.importFile(at: notUTF8)
        }

        let missing = FileManager.default.temporaryDirectory.appending(path: "quick-search-missing-\(UUID()).txt")
        await #expect(throws: (any Error).self) {
            try await model.importFile(at: missing)
        }

        #expect(model.items == ["a"])
        #expect(try await h.store.quickSearches() == ["a"])
    }

    /// The file is named `QuickSearchFile.fileName(at:)` in the temporary directory and holds
    /// `QuickSearchFile.export(_:)`.
    @Test func exportFileIsNamedAndFilled() async throws {
        let h = try Self.makeHarness()
        let model = h.model()
        await model.load()
        for text in ["fake a", "female:\"fake tag$\""] {
            #expect(await model.add(text))
        }
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let url = try QuickSearchExport(texts: model.items).writeFile(at: date)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(url.lastPathComponent == QuickSearchFile.fileName(at: date))
        #expect(url.lastPathComponent.wholeMatch(of: /QSearch_\d{8}_\d{6}\.txt/) != nil)
        #expect(url == FileManager.default.temporaryDirectory.appending(path: QuickSearchFile.fileName(at: date)))
        #expect(try String(contentsOf: url, encoding: .utf8) == QuickSearchFile.export(model.items))
        #expect(model.exportText() == QuickSearchFile.export(model.items))

        // Written again with the same date, the file is replaced.
        _ = try QuickSearchExport(texts: ["fake other"]).writeFile(at: date)
        #expect(try String(contentsOf: url, encoding: .utf8) == "#FEhViewer\nfake other")
    }

    /// Translations are read only while tags are shown translated.
    @Test func translationsFollowTheSetting() async throws {
        let h = try Self.makeHarness(translations: try await FakeTagTable.store())
        #expect(try await h.store.addQuickSearch("female:\"fake tag$\""))
        #expect(try await h.store.addQuickSearch("plain"))
        let model = h.model()

        h.settings.settings.showsTagTranslations = true
        await model.load()
        #expect(model.translations == ["female:\"fake tag$\"": "女性:示例标签"])

        h.settings.settings.showsTagTranslations = false
        await model.load()
        #expect(model.translations.isEmpty)
        #expect(model.items == ["female:\"fake tag$\"", "plain"])
    }

    @Test func missingStoreIsUnavailable() async throws {
        let h = try Self.makeHarness()
        let model = QuickSearchListModel(userData: nil, terms: h.terms, settings: h.settings)
        #expect(!model.isAvailable)
        await model.load()
        #expect(model.items.isEmpty)
        #expect(await model.add("fake") == false)
        #expect(model.items.isEmpty)
    }
}
