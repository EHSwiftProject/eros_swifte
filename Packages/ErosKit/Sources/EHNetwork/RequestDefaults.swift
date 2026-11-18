import EHModels

/// Per-phase request timeouts.
public struct RequestTimeouts: Sendable, Equatable {
    public let connect: Duration
    public let send: Duration
    public let receive: Duration

    public init(connect: Duration, send: Duration, receive: Duration) {
        self.connect = connect
        self.send = send
        self.receive = receive
    }
}

/// Request headers and timeouts shared with the Flutter app.
public enum RequestDefaults {
    public static let chromeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/95.0.4638.54 Safari/537.36 Edg/95.0.1020.30"

    public static let accept =
        "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.9"

    public static let acceptLanguage = "zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6"

    /// Timeouts for requests to the given site; EX is given more headroom.
    public static func timeouts(for site: EHSite) -> RequestTimeouts {
        switch site {
        case .eh: RequestTimeouts(connect: .seconds(10), send: .seconds(8), receive: .seconds(20))
        case .ex: RequestTimeouts(connect: .seconds(15), send: .seconds(8), receive: .seconds(25))
        }
    }
}
