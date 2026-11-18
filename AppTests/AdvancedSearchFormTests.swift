import Testing

@testable import Eros

/// `AdvancedSearchForm`'s page fields: what a typed text becomes, shown and kept. The field always shows the bound the
/// search holds (its digits, or nothing), so the two never differ.
@MainActor @Suite struct AdvancedSearchFormTests {
    @Test func pageTextsKeepTheirDigits() {
        #expect(AdvancedSearchForm.pageInput("20") == PageBoundInput(text: "20", bound: 20))
        #expect(AdvancedSearchForm.pageInput(" 2a0 ") == PageBoundInput(text: "20", bound: 20))
        #expect(AdvancedSearchForm.pageInput("200x") == PageBoundInput(text: "200", bound: 200))
        // Only ASCII digits: a full-width or Arabic-Indic digit is dropped, not read.
        #expect(AdvancedSearchForm.pageInput("１２") == PageBoundInput(text: "", bound: nil))
        #expect(AdvancedSearchForm.pageInput("٣") == PageBoundInput(text: "", bound: nil))
        // At most nine digits (what `CustomGroup` reads back).
        #expect(AdvancedSearchForm.pageInput("1234567890") == PageBoundInput(text: "123456789", bound: 123_456_789))
    }

    @Test func zeroIsNoBound() {
        #expect(AdvancedSearchForm.pageInput("") == PageBoundInput(text: "", bound: nil))
        #expect(AdvancedSearchForm.pageInput("0") == PageBoundInput(text: "", bound: nil))
        #expect(AdvancedSearchForm.pageInput("000") == PageBoundInput(text: "", bound: nil))
        // Leading zeros go: the field shows the number the search holds.
        #expect(AdvancedSearchForm.pageInput("007") == PageBoundInput(text: "7", bound: 7))
        #expect(AdvancedSearchForm.pageInput("0100") == PageBoundInput(text: "100", bound: 100))
    }

    @Test func boundsShowAsTheirText() {
        #expect(AdvancedSearchForm.pageText(nil) == "")
        #expect(AdvancedSearchForm.pageText(20) == "20")
        // A stored bound shows as it is, 0 included (typing replaces it).
        #expect(AdvancedSearchForm.pageText(0) == "0")
    }
}
