import EHModels
import Testing

@Suite struct TagNamespaceTests {
    @Test(arguments: [
        ("f", "female"), ("a", "artist"), ("x", "mixed"), ("o", "other"), ("cos", "cosplayer"), ("misc", "misc"),
        ("female", "female"), (" Female ", "female"), ("uploader", "uploader"), ("temp", "temp"),
        ("rows", nil), ("z", nil), ("", nil),
    ] as [(String, String?)])
    func fullNamesFollowFlutter(_ input: String, _ expected: String?) {
        #expect(TagNamespace.fullName(for: input) == expected)
    }

    @Test(arguments: [
        ("female", "f"), ("cosplayer", "cos"), ("misc", "misc"), ("Language", "l"),
        ("uploader", nil), ("temp", nil), ("f", nil), ("rows", nil),
    ] as [(String, String?)])
    func abbreviationsFollowFlutter(_ input: String, _ expected: String?) {
        #expect(TagNamespace.abbreviation(for: input) == expected)
    }

    @Test func everyAbbreviationRoundTrips() throws {
        for short in ["a", "c", "f", "g", "l", "m", "p", "r", "o", "x", "cos", "misc"] {
            let full = try #require(TagNamespace.fullName(for: short))
            #expect(TagNamespace.abbreviation(for: full) == short)
        }
    }
}
