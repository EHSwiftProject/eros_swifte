import EHNetwork
import Foundation
import Synchronization

/// What `MockURLProtocol` answers to one request.
public struct MockResponse: Sendable {
    public let status: Int
    /// Response headers. A redirect adds `Location` (its target) unless one is given.
    public let headers: [String: String]
    public let body: Data
    /// Offers this response (`status` should be a 3xx) to the session as a redirect to this URL. When the session
    /// follows it, the mock answers the new request as well; when the session refuses it, this response and body
    /// are the result, after `MockURLProtocol.refusalDelay`. 303, and 301 or 302 after a POST, continue as a GET
    /// without a body (as browsers do).
    public let redirectTo: URL?
    /// Holds the answer until the gate opens (`MockGate`); nil answers at once. Not for a redirect.
    public let heldBy: MockGate?

    public init(
        status: Int = 200, headers: [String: String] = [:], body: Data = Data(), redirectTo: URL? = nil,
        heldBy: MockGate? = nil
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.redirectTo = redirectTo
        self.heldBy = heldBy
    }
}

/// Holds the answers given to it (`MockResponse.heldBy`) until `open()`. The request is recorded at once, and the
/// session's loading thread is not held meanwhile: the session's other requests go out and are answered, which a
/// responder that waits would stop (the session loads every request of a custom protocol on one thread). Once open,
/// nothing is held.
public final class MockGate: Sendable {
    private struct State {
        var isOpen = false
        var heldCount = 0
        var waiting: [@Sendable () -> Void] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// How many answers it has held, the ones delivered since included.
    public var heldCount: Int { state.withLock { $0.heldCount } }

    /// Delivers every answer held, and from now on lets every answer through at once.
    public func open() {
        let waiting = state.withLock { state in
            state.isOpen = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for deliver in waiting { deliver() }
    }

    /// Runs `deliver` now when open, else when `open()` is called.
    fileprivate func hold(_ deliver: @escaping @Sendable () -> Void) {
        let isOpen = state.withLock { state in
            if !state.isOpen {
                state.heldCount += 1
                state.waiting.append(deliver)
            }
            return state.isOpen
        }
        if isOpen { deliver() }
    }
}

/// A URL protocol that answers from registered responders and never touches the network.
///
/// A `MockSession`'s configurator installs it first in a session's `protocolClasses` and adds the `X-Eros-Mock`
/// header naming the registration. It takes every request of such a session: a request without a registered
/// id fails with `URLError(.unsupportedURL)` instead of falling through to the system's HTTP stack.
/// Registrations live in a process-wide table (behind a `Mutex`), so tests running in parallel each install
/// their own and never see each other's requests.
public final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    /// The header the configurator adds; its value is the registration's id.
    public static let headerName = "X-Eros-Mock"

    /// How long a redirect waits to be followed before the mock takes it as refused and finishes with the 3xx.
    ///
    /// Following a redirect (or cancelling the task) stops the protocol; refusing it leaves the protocol to finish
    /// with the 3xx response, and nothing tells it so. Finishing at once, while the session is still deciding,
    /// races the decision: now and then the task ends with the 3xx although the redirect is followed, or Foundation
    /// traps in `data(for:delegate:)`. So a redirect hop must decide within this time (the client's throttle
    /// included), and a refused redirect costs this much.
    public static let refusalDelay: Duration = .seconds(1)

    fileprivate typealias Responder = @Sendable (URLRequest) throws -> MockResponse

    fileprivate struct Registration {
        let responder: Responder
        var requests: [URLRequest] = []
    }

    fileprivate static let registry = Mutex<[String: Registration]>([:])

    /// Whether the session has stopped this instance (it followed a redirect, cancelled, or the load finished).
    private let isStopped = Mutex(false)

    /// Registers a responder; requests are matched to it by the X-Eros-Mock header the configurator adds.
    ///
    /// The responder runs on the session's loading thread, once per request (each redirect hop is a request); a
    /// thrown error fails the request with that error. It receives the request as recorded: body read from
    /// `httpBodyStream` into `httpBody`, the session's additional headers included.
    public static func install(_ responder: @escaping @Sendable (URLRequest) throws -> MockResponse) -> MockSession {
        let id = UUID().uuidString
        registry.withLock { $0[id] = Registration(responder: responder) }
        return MockSession(id: id)
    }

    override public class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override public func startLoading() {
        let request = Self.readingBody(of: request)
        let responder: Responder? = request.value(forHTTPHeaderField: Self.headerName).flatMap { id in
            Self.registry.withLock { registrations in
                guard registrations[id] != nil else { return nil }
                registrations[id]!.requests.append(request)
                return registrations[id]!.responder
            }
        }
        guard let responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            deliver(try responder(request), for: request)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override public func stopLoading() {
        isStopped.withLock { $0 = true }
    }

    private func deliver(_ mock: MockResponse, for request: URLRequest) {
        guard let client, let url = request.url else { return }
        var headers = mock.headers
        if let target = mock.redirectTo,
           !headers.keys.contains(where: { $0.caseInsensitiveCompare("Location") == .orderedSame }) {
            headers["Location"] = target.absoluteString
        }
        let response = HTTPURLResponse(url: url, statusCode: mock.status, httpVersion: "HTTP/1.1", headerFields: headers)
        guard let response else {
            client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        guard let target = mock.redirectTo else {
            if let gate = mock.heldBy {
                hold(by: gate, response: response, body: mock.body)
            } else {
                finish(with: response, body: mock.body)
            }
            return
        }
        let next = Self.redirected(request, to: target, status: mock.status)
        client.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        // See `refusalDelay`: finish with the 3xx only if the session has not followed the redirect by then.
        let delay = DispatchTimeInterval.milliseconds(Int(Self.refusalDelay / .milliseconds(1)))
        let body = mock.body
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            guard !isStopped.withLock({ $0 }) else { return }
            finish(with: response, body: body)
        }
    }

    /// Delivers `response` and `body` once `gate` opens, on the thread this load started on (where URLProtocol's
    /// client expects its calls, and where `stopLoading()` runs too, so a load stopped meanwhile is told apart).
    private func hold(by gate: MockGate, response: HTTPURLResponse, body: Data) {
        loadingThread = Thread.current
        loadingModes = [(RunLoop.current.currentMode ?? .default).rawValue]
        let answer = HeldAnswer(response: response, body: body)
        gate.hold { [self] in
            guard let thread = loadingThread else { return }
            perform(#selector(deliverHeld(_:)), on: thread, with: answer, waitUntilDone: false, modes: loadingModes)
        }
    }

    /// The thread a held load started on, and its run loop's mode (`hold(by:response:body:)`); set before the gate
    /// can deliver, read after.
    private var loadingThread: Thread?
    private var loadingModes: [String] = []

    /// See `hold(by:response:body:)`.
    @objc private func deliverHeld(_ answer: HeldAnswer) {
        guard !isStopped.withLock({ $0 }) else { return }
        finish(with: answer.response, body: answer.body)
    }

    /// An answer `hold(by:response:body:)` keeps for later.
    private final class HeldAnswer: NSObject, Sendable {
        let response: HTTPURLResponse
        let body: Data

        init(response: HTTPURLResponse, body: Data) {
            self.response = response
            self.body = body
        }
    }

    private func finish(with response: HTTPURLResponse, body: Data) {
        guard let client else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty {
            client.urlProtocol(self, didLoad: body)
        }
        client.urlProtocolDidFinishLoading(self)
    }

    /// The request a redirect continues with.
    private static func redirected(_ request: URLRequest, to target: URL, status: Int) -> URLRequest {
        var next = request
        next.url = target
        if status == 303 || ((status == 301 || status == 302) && request.httpMethod == "POST") {
            next.httpMethod = "GET"
            next.httpBody = nil
            next.setValue(nil, forHTTPHeaderField: "Content-Type")
        }
        return next
    }

    /// `request` with the bytes of its `httpBodyStream` (URLSession turns `httpBody` into one) as `httpBody`.
    private static func readingBody(of request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        var body = Data()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        var copy = request
        copy.httpBody = body
        return copy
    }
}

/// One `MockURLProtocol` registration: the configurator that routes a session to it, and what it received.
public struct MockSession: Sendable {
    /// Inserts MockURLProtocol first in `protocolClasses` and adds the X-Eros-Mock header with this registration's id.
    /// Chain it inside another configurator to add settings of your own.
    public let configurator: SessionConfigurator
    private let id: String

    fileprivate init(id: String) {
        self.id = id
        configurator = SessionConfigurator(usesCustomProxy: false) { configuration in
            configuration.protocolClasses = [MockURLProtocol.self as AnyClass] + (configuration.protocolClasses ?? [])
            var headers = configuration.httpAdditionalHeaders ?? [:]
            headers[MockURLProtocol.headerName] = id
            configuration.httpAdditionalHeaders = headers
        }
    }

    /// The requests received so far, oldest first, bodies read from `httpBodyStream`; empty after `remove()`.
    public func requests() -> [URLRequest] {
        MockURLProtocol.registry.withLock { $0[id]?.requests ?? [] }
    }

    /// Drops the registration: later requests of its sessions fail with `URLError(.unsupportedURL)`.
    public func remove() {
        _ = MockURLProtocol.registry.withLock { $0.removeValue(forKey: id) }
    }
}
