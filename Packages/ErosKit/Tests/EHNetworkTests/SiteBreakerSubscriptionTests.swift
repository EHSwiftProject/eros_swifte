@testable import EHNetwork
import Foundation
import Testing

/// `SiteBreaker.updates()` subscriptions end with their listener: nothing is kept for a stream no one reads.
@Suite struct SiteBreakerSubscriptionTests {
    @Test func endedSubscriptionsAreRemoved() async throws {
        let breaker = SiteBreaker()
        let firstListener: Task<Void, Never>
        let secondListener: Task<[SitePause?], Never>
        do {
            // Only the listeners hold the streams.
            let first = await breaker.updates()
            let second = await breaker.updates()
            firstListener = Task { for await _ in first {} }
            secondListener = Task {
                var values: [SitePause?] = []
                for await value in second {
                    values.append(value)
                    if values.count == 2 { break }
                }
                return values
            }
        }
        #expect(await breaker.subscriberCount == 2)
        firstListener.cancel()
        #expect(await waitUntil { await breaker.subscriberCount == 1 })
        // The other one still hears the next pause; once it stops listening, it is removed too.
        let pause = try #require(await breaker.record(.tooManyRequests, at: URL(string: "https://e-hentai.org/")!))
        #expect(await secondListener.value == [nil, pause])
        #expect(await waitUntil { await breaker.subscriberCount == 0 })
    }
}
