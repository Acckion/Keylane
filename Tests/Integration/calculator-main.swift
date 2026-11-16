import Combine
import Foundation
import KeylaneCore

final class FixtureProtocol: URLProtocol {
    static let lock = NSLock()
    static var replies: [(URLProtocol) -> Void] = []
    static var requests = 0
    static var cancellations = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock {
            Self.requests += 1
            return Self.replies.removeFirst()
        }
        reply(self)
    }
    override func stopLoading() { Self.lock.withLock { Self.cancellations += 1 } }
}

func wait(_ label: String, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(12)
    while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    precondition(condition(), label)
}

func response(_ body: Data, status: Int = 200) -> (URLProtocol) -> Void {
    { request in
        let http = HTTPURLResponse(url: request.request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        request.client?.urlProtocol(request, didReceive: http, cacheStoragePolicy: .notAllowed)
        request.client?.urlProtocol(request, didLoad: body)
        request.client?.urlProtocolDidFinishLoading(request)
    }
}

func failure(_ error: URLError) -> (URLProtocol) -> Void {
    { $0.client?.urlProtocol($0, didFailWithError: error) }
}

func configure(_ replies: [(URLProtocol) -> Void]) {
    FixtureProtocol.lock.withLock { FixtureProtocol.replies = replies }
}

let locale = Locale(identifier: "en_US_POSIX")
let usd = CalculatorConversion("100 USD to CNY", locale: locale)!
let yen = CalculatorConversion("5 JPY to USD", locale: locale)!
let key = "calculatorECBReferenceRates"
let suite = "org.keylane.calculator.fixture." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }

if CommandLine.arguments.contains("--live") {
    let exchange = CalculatorExchangeRates(defaults: defaults)
    exchange.startPresenting()
    precondition(exchange.result(usd, locale: locale)?.detail.contains("正在获取") == true)
    wait("ECB returned a parsed rate") {
        exchange.result(usd, locale: locale)?.value != nil
    }
    let result = exchange.result(usd, locale: locale)!
    print("PASS ECB live: \(result.value!) · \(result.detail)")
    exit(0)
}

let configuration = URLSessionConfiguration.ephemeral
configuration.protocolClasses = [FixtureProtocol.self]
let session = URLSession(configuration: configuration)
let exchange = CalculatorExchangeRates(defaults: defaults, session: session)
func result(_ query: CalculatorConversion = usd) -> (value: String?, detail: String) {
    exchange.result(query, locale: locale)!
}
func requestCount() -> Int { FixtureProtocol.lock.withLock { FixtureProtocol.requests } }
func cancellationCount() -> Int { FixtureProtocol.lock.withLock { FixtureProtocol.cancellations } }
let stale = Data("""
<Cube><Cube time="2020-01-02"><Cube currency="USD" rate="2"/><Cube currency="CNY" rate="8"/></Cube></Cube>
""".utf8)
let fresh = Data("""
<Cube><Cube time="2026-11-12"><Cube currency="USD" rate="4"/><Cube currency="CNY" rate="8"/><Cube currency="JPY" rate="20"/></Cube></Cube>
""".utf8)

configure([failure(URLError(.notConnectedToInternet))])
precondition(result().value == nil && requestCount() == 0)
exchange.startPresenting()
precondition(result().detail.contains("正在获取"))
wait("offline without cache") { result().detail.contains("离线") }
precondition(result().detail.contains("无缓存"))
exchange.stop()

configure([response(Data("<Cube/>".utf8)), response(Data(), status: 503)])
for _ in 0..<2 {
    exchange.startPresenting()
    _ = result()
    wait("malformed XML or HTTP failure") { result().detail.contains("刷新失败") }
    precondition(result().value == nil)
    exchange.stop()
}

defaults.set(try JSONEncoder().encode(ECBReferenceRates(xml: stale)!), forKey: key)
configure([failure(URLError(.notConnectedToInternet))])
exchange.startPresenting()
precondition(result().value == "400 CNY")
wait("offline with stale cache") { result().detail.contains("离线") }
precondition(result().detail.contains("数据日期 2020-01-02") && result().detail.contains("数据已过期"))
precondition(result(yen).value == nil && result(yen).detail.contains("暂无 JPY / USD"))
exchange.stop()

let before = requestCount()
let cancelledBefore = cancellationCount()
configure([{ _ in }, response(fresh)])
exchange.startPresenting()
_ = result()
wait("first request reached transport") { requestCount() == before + 1 }
_ = result(yen)
precondition(requestCount() == before + 1)
exchange.endPresentation()
wait("closing cancels the request") { cancellationCount() > cancelledBefore }
_ = result()
precondition(requestCount() == before + 1, "Hidden query must not start another request")
exchange.startPresenting()
_ = result(yen)
wait("reopened query uses fresh reference table") { result(yen).value == "1 USD" }
precondition(result().value == "200 CNY" && result().detail.contains("数据日期 2026-11-12"))
precondition(requestCount() == before + 2)
exchange.endPresentation()
exchange.startPresenting()
precondition(result(yen).value == "1 USD" && requestCount() == before + 2)
exchange.stop()
print("PASS calculator: no-data, malformed XML, HTTP failure, offline stale cache, unsupported currency, cancellation, rapid query change and reopen")
