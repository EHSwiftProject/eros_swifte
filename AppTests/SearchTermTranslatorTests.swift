import EHModels
import EHStore
import Testing

@testable import Eros

/// `SearchTermTranslator` over `FakeTagTable`'s made-up rows.
@MainActor @Suite struct SearchTermTranslatorTests {
    @Test func translatesEachTerm() async throws {
        let translator = SearchTermTranslator(translations: try await FakeTagTable.store())

        let both = await translator.translation(of: "f:\"fake tag$\" o:\"fake other$\"")
        #expect(both == "女性:示例标签   其他:其他示例")
        // An untranslated term stays (its namespace in Chinese when it has one); a name alone is looked up too.
        let mixed = await translator.translation(of: "female:\"fake tag$\" plain f:unknown")
        #expect(mixed == "女性:示例标签   plain   女性:unknown")
        #expect(await translator.translation(of: "fakeartist$") == "示例作者")
    }

    @Test func quotedTermsStayTogetherAndMinusIsKept() async throws {
        let translator = SearchTermTranslator(translations: try await FakeTagTable.store())

        #expect(await translator.translation(of: "-f:\"fake tag$\"") == "-女性:示例标签")
        let spaced = await translator.translation(of: "  -o:\"fake  other$\"\n-a:fakeartist")
        #expect(spaced == "-其他:其他示例   -作者:示例作者")
    }

    @Test func untranslatedTextGivesNil() async throws {
        let translator = SearchTermTranslator(translations: try await FakeTagTable.store())
        #expect(await translator.translation(of: "f:\"unknown tag$\" plain") == nil)
        #expect(await translator.translation(of: "") == nil)

        #expect(await SearchTermTranslator(translations: nil).translation(of: "f:\"fake tag$\"") == nil)
    }
}
