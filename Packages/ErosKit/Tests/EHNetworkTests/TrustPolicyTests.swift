import EHNetwork
import Foundation
import Security
import Testing

/// `TrustPolicy.answer(_:)`: how `EHClient`'s sessions (and the app's image sessions) answer authentication
/// challenges.
@Suite struct TrustPolicyTests {
    /// A self-signed certificate made for this test (CN trust-policy.invalid, key discarded), only so that a
    /// `SecTrust` exists; nothing ever trusts it.
    private static let certificate = """
        MIIBdDCCARqgAwIBAgIUQ2X+M0h7u7/NJzNUknnJsFsjbWwwCgYIKoZIzj0EAwIwHzEdMBsGA1UEAwwUdHJ1c3QtcG9saWN5Lmlu\
        dmFsaWQwIBcNMjYxMTE2MjI1NTQwWhgPMjEyNjEwMjMyMjU1NDBaMB8xHTAbBgNVBAMMFHRydXN0LXBvbGljeS5pbnZhbGlkMFkw\
        EwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEGsvD+VadtnUhD6XuW19fKObY0gmA+g4rNQwLdPTUFvc4l6jdlof6XJaGmAruMqFJxx8H\
        NjjkF6CgZ96NRJm0BKMyMDAwHQYDVR0OBBYEFCEVCxZr7rGaqP80ydLJWIC8FnQrMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0E\
        AwIDSAAwRQIhAL3BIg6wX3y+drKkkwmJZ4ou3/P9jZUgjHDcsXbqcCBoAiBg/Q6m+w2u8PIvy6Pye8KtSGTqS/nmLgOWCKcPLHY3\
        og==
        """

    /// A protection space that hands out `trust` as its server trust (the system's own only does so for a real
    /// connection).
    private final class TrustingSpace: URLProtectionSpace, @unchecked Sendable {
        private let trust: SecTrust?

        init(method: String, trust: SecTrust?) {
            self.trust = trust
            super.init(host: "e-hentai.org", port: 443, protocol: "https", realm: nil, authenticationMethod: method)
        }

        required init?(coder: NSCoder) { nil }

        override var serverTrust: SecTrust? { trust }
    }

    /// Never asked: `answer(_:)` returns a disposition instead of calling the sender.
    private final class Sender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private static func trust() throws -> SecTrust {
        let data = try #require(Data(base64Encoded: certificate))
        let certificate = try #require(SecCertificateCreateWithData(nil, data as CFData))
        var trust: SecTrust?
        try #require(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        return try #require(trust)
    }

    private static func challenge(method: String, trust: SecTrust?) -> URLAuthenticationChallenge {
        URLAuthenticationChallenge(
            protectionSpace: TrustingSpace(method: method, trust: trust), proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: Sender()
        )
    }

    @Test func strictLeavesEveryChallengeToTheSystem() throws {
        let trust = try Self.trust()
        for method in [NSURLAuthenticationMethodServerTrust, NSURLAuthenticationMethodHTTPBasic] {
            let (disposition, credential) = TrustPolicy.strict.answer(Self.challenge(method: method, trust: trust))
            #expect(disposition == .performDefaultHandling, "\(method)")
            #expect(credential == nil, "\(method)")
        }
    }

    @Test func ignoringCertificateErrorsAcceptsTheServerTrust() throws {
        let challenge = Self.challenge(method: NSURLAuthenticationMethodServerTrust, trust: try Self.trust())
        let (disposition, credential) = TrustPolicy.ignoreCertificateErrors.answer(challenge)
        #expect(disposition == .useCredential)
        #expect(credential != nil)
    }

    /// Without a server trust there is nothing to accept: the system decides, as under `.strict`.
    @Test func ignoringCertificateErrorsWithoutAServerTrustLeavesItToTheSystem() {
        let challenge = Self.challenge(method: NSURLAuthenticationMethodServerTrust, trust: nil)
        let (disposition, credential) = TrustPolicy.ignoreCertificateErrors.answer(challenge)
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }

    /// Only the certificate check is relaxed: a password challenge (HTTP Basic, a client certificate) is the
    /// system's, as under `.strict`.
    @Test func ignoringCertificateErrorsLeavesOtherChallengesToTheSystem() throws {
        let trust = try Self.trust()
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodClientCertificate] {
            let (disposition, credential) = TrustPolicy.ignoreCertificateErrors.answer(
                Self.challenge(method: method, trust: trust)
            )
            #expect(disposition == .performDefaultHandling, "\(method)")
            #expect(credential == nil, "\(method)")
        }
    }
}
