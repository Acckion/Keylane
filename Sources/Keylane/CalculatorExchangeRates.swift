import Combine
import Foundation
import KeylaneCore

final class CalculatorExchangeRates: ObservableObject {
    private enum RefreshState { case idle, loading, offline, failed }
    @Published private var state = RefreshState.idle
    private var rates: ECBReferenceRates?
    private var lastAttempt: TimeInterval?
    private let defaults: UserDefaults
    private let session: URLSession
    private let cacheKey = "calculatorECBReferenceRates"
    private static let source = "欧洲央行（ECB）"

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        rates = defaults.data(forKey: cacheKey).flatMap { try? JSONDecoder().decode(ECBReferenceRates.self, from: $0) }
    }

    var updates: AnyPublisher<Void, Never> {
        $state.dropFirst().receive(on: DispatchQueue.main).map { _ in () }.eraseToAnyPublisher()
    }

    func result(_ conversion: CalculatorConversion) -> (value: String?, detail: String)? {
        guard let pair = conversion.currencies else { return nil }
        refreshIfNeeded()
        let status: String
        switch state {
        case .idle: status = ""
        case .loading: status = " · 正在刷新"
        case .offline: status = " · 离线"
        case .failed: status = " · 刷新失败"
        }
        guard let rates else {
            return (nil, state == .loading ? "正在获取欧洲央行汇率…" : "无法获取欧洲央行汇率\(status) · 无缓存")
        }
        let age = rates.isStale() ? " · 数据已过期" : ""
        let detail = "\(Self.source) · 数据日期 \(rates.date)\(age)\(status)"
        guard let converted = rates.convert(conversion.amount, from: pair.source, to: pair.target) else {
            return (nil, "暂无 \(pair.source) / \(pair.target) 汇率 · \(detail)")
        }
        return (String(format: "%.12g", converted) + " " + pair.target, detail)
    }

    private func refreshIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        let interval: TimeInterval = state == .offline || state == .failed ? 30 : 900
        guard state != .loading, lastAttempt.map({ now - $0 >= interval }) ?? true else { return }
        lastAttempt = now
        state = .loading
        let url = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        session.dataTask(with: request) { [weak self] data, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let snapshot = statusCode == 200 ? data.flatMap(ECBReferenceRates.init(xml:)) : nil
            let offline = (error as? URLError).map { [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains($0.code) } ?? false
            DispatchQueue.main.async {
                guard let self else { return }
                if let snapshot {
                    if self.rates.map({ $0.date <= snapshot.date }) ?? true {
                        self.rates = snapshot
                        if let data = try? JSONEncoder().encode(snapshot) { self.defaults.set(data, forKey: self.cacheKey) }
                    }
                    self.state = .idle
                } else {
                    self.state = offline ? .offline : .failed
                }
            }
        }.resume()
    }
}
