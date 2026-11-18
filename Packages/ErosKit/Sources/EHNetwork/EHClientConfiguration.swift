import EHModels
import Foundation

/// Changes the `URLSessionConfiguration` of every session `EHClient` makes, after the client's own settings.
///
/// The seam for what the transport needs from outside: M7 sets a proxy here, tests install a mock `URLProtocol`.
public struct SessionConfigurator: Sendable {
    /// Changes nothing; no custom proxy.
    public static let none = SessionConfigurator(usesCustomProxy: false) { _ in }

    /// Whether it routes requests through a proxy the user configured; only then may certificate errors be ignored.
    public let usesCustomProxy: Bool
    private let body: @Sendable (URLSessionConfiguration) -> Void

    public init(usesCustomProxy: Bool, apply: @escaping @Sendable (URLSessionConfiguration) -> Void) {
        self.usesCustomProxy = usesCustomProxy
        body = apply
    }

    /// Runs the closure on `configuration`; a configurator can call another's `apply(to:)` to chain them.
    public func apply(to configuration: URLSessionConfiguration) {
        body(configuration)
    }
}

/// How the client answers authentication challenges.
public enum TrustPolicy: Sendable, Equatable {
    /// The system's own handling for every challenge, so a server certificate must pass the system's checks.
    case strict
    /// Accepts any server certificate (ServerTrust); every other challenge as `.strict`. Only with a custom proxy.
    case ignoreCertificateErrors

    /// `.useCredential` (with `URLCredential(trust:)`) for a ServerTrust challenge under `.ignoreCertificateErrors`;
    /// `.performDefaultHandling` otherwise.
    public func disposition(forAuthenticationMethod method: String) -> URLSession.AuthChallengeDisposition {
        switch self {
        case .strict:
            .performDefaultHandling
        case .ignoreCertificateErrors:
            method == NSURLAuthenticationMethodServerTrust ? .useCredential : .performDefaultHandling
        }
    }

    /// The answer to `challenge` for a session delegate's `urlSession(_:didReceive:)`: the disposition for its
    /// authentication method, where `.useCredential` carries `URLCredential(trust:)` and becomes
    /// `.performDefaultHandling` when the challenge has no server trust to accept. `EHClient`'s sessions answer with
    /// it, and so should every other session that follows the client's policy (the app's image sessions).
    public func answer(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let disposition = disposition(forAuthenticationMethod: challenge.protectionSpace.authenticationMethod)
        guard disposition == .useCredential else { return (disposition, nil) }
        guard let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// A client configuration the app must not use.
public enum ConfigurationError: Error, Equatable {
    /// `TrustPolicy.ignoreCertificateErrors` without a configurator that `usesCustomProxy`.
    case ignoringCertificatesRequiresCustomProxy
}

/// How `EHClient` builds its sessions and answers certificate challenges.
public struct EHClientConfiguration: Sendable {
    /// No session changes, strict trust.
    public static let standard = EHClientConfiguration(checked: .none, trustPolicy: .strict)

    public let sessionConfigurator: SessionConfigurator
    public let trustPolicy: TrustPolicy

    /// Throws `ConfigurationError.ignoringCertificatesRequiresCustomProxy` for `.ignoreCertificateErrors` unless
    /// `sessionConfigurator.usesCustomProxy`.
    public init(sessionConfigurator: SessionConfigurator = .none, trustPolicy: TrustPolicy = .strict) throws {
        guard trustPolicy == .strict || sessionConfigurator.usesCustomProxy else {
            throw ConfigurationError.ignoringCertificatesRequiresCustomProxy
        }
        self.init(checked: sessionConfigurator, trustPolicy: trustPolicy)
    }

    private init(checked sessionConfigurator: SessionConfigurator, trustPolicy: TrustPolicy) {
        self.sessionConfigurator = sessionConfigurator
        self.trustPolicy = trustPolicy
    }
}

/// The two timeouts URLSession has, for one site.
public struct URLSessionTimeouts: Sendable, Equatable {
    /// `timeoutIntervalForRequest`: the longest wait for more data before a request fails.
    public let idle: Duration
    /// `timeoutIntervalForResource`: the longest a whole request may take.
    public let resource: Duration

    public init(idle: Duration, resource: Duration) {
        self.idle = idle
        self.resource = resource
    }
}

extension RequestTimeouts {
    /// URLSession has no connect or send timeout: idle = receive; resource = connect + send + receive
    /// (EH 20 s and 38 s, EX 25 s and 48 s).
    public var urlSession: URLSessionTimeouts {
        URLSessionTimeouts(idle: receive, resource: connect + send + receive)
    }
}

extension Duration {
    /// The duration in seconds, for Foundation's `TimeInterval` properties.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
