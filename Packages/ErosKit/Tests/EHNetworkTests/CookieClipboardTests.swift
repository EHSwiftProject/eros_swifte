import EHNetwork
import Foundation
import Testing

/// Every value here is made up (member id 1234567, pass hash 0123…cdef).
@Suite struct CookieClipboardTests {
    private static let memberID = "1234567"
    private static let passHash = "0123456789abcdef0123456789abcdef"
    private static let expected = CookieCredentials(memberID: memberID, passHash: passHash)

    @Test func plainTextTokensParse() {
        let text = "ipb_member_id=\(Self.memberID); ipb_pass_hash=\(Self.passHash)"
        #expect(CookieClipboard.parse(text) == Self.expected)
        // Bare tokens on two lines, and the order reversed.
        #expect(CookieClipboard.parse("\(Self.memberID)\n\(Self.passHash)") == Self.expected)
        #expect(CookieClipboard.parse("\(Self.passHash) \(Self.memberID)") == Self.expected)
        // ":" and "&" separate as well.
        #expect(CookieClipboard.parse("ipb_member_id:\(Self.memberID)&ipb_pass_hash:\(Self.passHash)") == Self.expected)
    }

    @Test func jsonExportParses() {
        let text = """
        [{"name":"ipb_member_id","value":"\(Self.memberID)"},{"name":"ipb_pass_hash","value":"\(Self.passHash)"}]
        """
        #expect(CookieClipboard.parse(text) == Self.expected)
        // A browser extension's export: more keys per cookie, other cookies, pretty-printed.
        let export = """
        [
          {"domain": ".e-hentai.org", "name": "sk", "value": "sk-fake-0001", "path": "/"},
          {"domain": ".e-hentai.org", "name": "ipb_pass_hash", "value": "\(Self.passHash)", "hostOnly": false},
          {"domain": ".e-hentai.org", "name": "ipb_member_id", "value": "\(Self.memberID)", "secure": true}
        ]
        """
        #expect(CookieClipboard.parse(export) == Self.expected)
    }

    @Test func incompleteTextGivesNil() {
        #expect(CookieClipboard.parse("ipb_member_id=\(Self.memberID)") == nil)
        #expect(CookieClipboard.parse("ipb_pass_hash=\(Self.passHash)") == nil)
        #expect(CookieClipboard.parse("") == nil)
        #expect(CookieClipboard.parse("fake random text, nothing to see") == nil)
        // A pass hash must be 32 lowercase hexadecimal characters.
        #expect(CookieClipboard.parse("\(Self.memberID) \(Self.passHash.uppercased())") == nil)
        #expect(CookieClipboard.parse("\(Self.memberID) \(Self.passHash.dropLast())") == nil)
        // JSON without one of the two, JSON that is not an array of cookies, and broken JSON.
        #expect(CookieClipboard.parse(#"[{"name":"ipb_member_id","value":"1234567"}]"#) == nil)
        #expect(CookieClipboard.parse(#"{"ipb_member_id":"1234567","ipb_pass_hash":"\#(Self.passHash)"}"#) == nil)
        #expect(CookieClipboard.parse(#"[{"name":"ipb_member_id","value":"1234567"},"#) == nil)
    }

    /// A cookie string holds other numbers too (`nw=1`, the expiry of a cookies.txt line): the value after the
    /// cookie's name wins over any other token.
    @Test func namedValuesWinOverOtherNumbers() {
        let header = "nw=1; ipb_member_id=\(Self.memberID); ipb_pass_hash=\(Self.passHash); star=1-1; nw=1"
        #expect(CookieClipboard.parse(header) == Self.expected)
        let cookiesTxt = """
        .e-hentai.org\tTRUE\t/\tTRUE\t1893456000\tipb_member_id\t\(Self.memberID)
        .e-hentai.org\tTRUE\t/\tTRUE\t1893456000\tipb_pass_hash\t\(Self.passHash)
        """
        #expect(CookieClipboard.parse(cookiesTxt) == Self.expected)
    }

    @Test func credentialsDescriptionsShowNoValues() {
        let credentials = CookieCredentials(memberID: Self.memberID, passHash: Self.passHash)
        var dumped = ""
        dump(credentials, to: &dumped)
        for text in [String(describing: credentials), String(reflecting: credentials), dumped] {
            #expect(!text.contains(Self.memberID))
            #expect(!text.contains(Self.passHash))
        }
    }
}
