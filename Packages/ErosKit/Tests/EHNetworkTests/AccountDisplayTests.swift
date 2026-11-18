import EHModels
import EHNetwork
import Foundation
import Testing

@Suite struct AccountDisplayTests {
    private static let avatar = URL(string: "https://forums.e-hentai.org/uploads/av-0.jpg")!

    @Test func displayNameWinsOverUsername() {
        let account = AccountInfo(
            method: .password, username: "fake_user", displayName: "Fake Nickname", avatarURL: Self.avatar
        )
        #expect(AccountDisplay.resolve(account) == .init(name: "Fake Nickname", avatarURL: Self.avatar))
    }

    @Test func usernameIsTheFallback() {
        let account = AccountInfo(method: .password, username: "fake_user")
        #expect(AccountDisplay.resolve(account) == .init(name: "fake_user", avatarURL: nil))
    }

    @Test func cookieAndWebLoginsWithoutProfileHaveNoName() {
        for method in [LoginMethod.cookie, .web] {
            #expect(AccountDisplay.resolve(AccountInfo(method: method)) == .init(name: nil, avatarURL: nil))
        }
    }
}
