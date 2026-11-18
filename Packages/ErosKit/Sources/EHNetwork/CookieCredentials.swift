import Foundation

/// The two cookies a cookie login is made of, as typed or pasted.
///
/// `description` and the mirror show no values: the pass hash is as good as the password.
public struct CookieCredentials: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    /// `ipb_member_id`.
    public var memberID: String
    /// `ipb_pass_hash`.
    public var passHash: String

    public init(memberID: String, passHash: String) {
        self.memberID = memberID
        self.passHash = passHash
    }

    /// "CookieCredentials(memberID: <n characters>, passHash: <n characters>)".
    public var description: String {
        "CookieCredentials(memberID: \(memberID.count) characters, passHash: \(passHash.count) characters)"
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["description": description])
    }

    /// Checks the form a cookie login takes, without any store or request: the member id ASCII digits, not zero and
    /// within an `Int`, the pass hash 32 lowercase hexadecimal characters; nothing is trimmed.
    /// `AccountService.logIn(with:)` checks with it, so the app can refuse typed values before it prepares the login.
    /// - Throws: `LoginError.invalidMemberID`, else `LoginError.invalidPassHash`.
    public func validate() throws(LoginError) {
        guard Self.isMemberID(memberID) else { throw .invalidMemberID }
        guard Self.isPassHash(passHash) else { throw .invalidPassHash }
    }

    /// All ASCII digits, fits an `Int`, not zero: a member id the cookie store takes for signed in.
    static func isMemberID(_ value: String) -> Bool {
        isDigits(value) && Int(value).map { $0 != 0 } == true
    }

    /// 32 lowercase ASCII hexadecimal characters.
    static func isPassHash(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { isDigit($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }
    }

    /// Non-empty, ASCII digits only (no other script's digits).
    static func isDigits(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy(isDigit)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}

/// Reads a member id and a pass hash out of text the user copied.
public enum CookieClipboard {
    /// Text without "{": split on whitespace, ":", ";", "&", "="; a token of digits is the member id, 32 lowercase hex the pass hash.
    /// Otherwise a JSON array of {"name", "value"} objects (browser cookie export). nil unless both are found.
    ///
    /// In text, the token right after a token "ipb_member_id" (or "ipb_pass_hash") is taken first when it has the
    /// right form, so a cookie string's other numbers (`nw=1`, a cookies.txt line's expiry) are not mistaken for the
    /// member id; otherwise the first token of the form. A 32-digit token is the pass hash when nothing else is.
    /// In JSON, the first object of each name whose value is a non-empty string; the values are not checked (the
    /// login does that).
    public static func parse(_ text: String) -> CookieCredentials? {
        text.contains("{") ? parseJSON(text) : parseTokens(text)
    }

    private static let separators: Set<Character> = [":", ";", "&", "="]

    private static func parseTokens(_ text: String) -> CookieCredentials? {
        let tokens = text.split { $0.isWhitespace || separators.contains($0) }.map(String.init)
        guard let hash = index(in: tokens, named: CookieNames.passHash, where: CookieCredentials.isPassHash),
              let id = index(in: tokens, named: CookieNames.memberID, excluding: hash, where: CookieCredentials.isDigits)
        else { return nil }
        return CookieCredentials(memberID: tokens[id], passHash: tokens[hash])
    }

    /// The index of the token after the first `name` token when it passes `test`, else of the first token that does.
    private static func index(
        in tokens: [String], named name: String, excluding excluded: Int? = nil, where test: (String) -> Bool
    ) -> Int? {
        let named = tokens.indices.first { index in
            tokens[index] == name && index + 1 < tokens.count && index + 1 != excluded && test(tokens[index + 1])
        }
        if let named { return named + 1 }
        return tokens.indices.first { $0 != excluded && test(tokens[$0]) }
    }

    private static func parseJSON(_ text: String) -> CookieCredentials? {
        guard let list = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any] else { return nil }
        var values: [String: String] = [:]
        for case let object as [String: Any] in list {
            guard let name = object["name"] as? String, let value = object["value"] as? String, !value.isEmpty,
                  values[name] == nil
            else { continue }
            values[name] = value
        }
        guard let memberID = values[CookieNames.memberID], let passHash = values[CookieNames.passHash] else { return nil }
        return CookieCredentials(memberID: memberID, passHash: passHash)
    }
}
