import EHModels
import EHNetwork
import Testing

struct RequestDefaultsTests {
    @Test func timeoutsMatchFlutter() {
        #expect(RequestDefaults.timeouts(for: .eh) == RequestTimeouts(connect: .seconds(10), send: .seconds(8), receive: .seconds(20)))
        #expect(RequestDefaults.timeouts(for: .ex) == RequestTimeouts(connect: .seconds(15), send: .seconds(8), receive: .seconds(25)))
    }

    @Test func headersMatchFlutter() {
        #expect(RequestDefaults.chromeUserAgent == "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/95.0.4638.54 Safari/537.36 Edg/95.0.1020.30")
        #expect(RequestDefaults.accept == "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.9")
        #expect(RequestDefaults.acceptLanguage == "zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6")
    }
}
