import CryptoKit
import Foundation

/// Local learning for launcher results. Only a digest of each normalized query is stored.
public struct SearchUsageHistory: Codable, Equatable {
    public static let storageKey = "launcherSearchUsage.v1"

    private struct Activity: Codable, Equatable {
        let weight: Double
        let date: Date

        func score(at now: Date) -> Double {
            let days = max(0, now.timeIntervalSince(date)) / 86_400
            return weight * pow(0.5, days / 14)
        }

        static func record(_ previous: Self?, at now: Date) -> Self {
            .init(weight: min(32, 1 + (previous?.score(at: now) ?? 0)), date: now)
        }
    }

    private struct ResultUsage: Codable, Equatable {
        var activity: Activity?
        var queries: [String: Activity] = [:]
    }

    private var results: [String: ResultUsage] = [:]

    public init() {}

    public static func queryKey(_ text: String) -> String? {
        let normalized = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                      locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty, normalized.utf8.count <= 1024 else { return nil }
        return Data(SHA256.hash(data: Data(normalized.utf8))).base64EncodedString()
    }

    public mutating func record(id: String, queryKey: String? = nil, at now: Date = .now) {
        var usage = results[id, default: ResultUsage()]
        usage.activity = Activity.record(usage.activity, at: now)
        if let queryKey {
            if usage.queries[queryKey] == nil, usage.queries.count >= 8,
               let oldest = usage.queries.min(by: { $0.value.date < $1.value.date })?.key {
                usage.queries.removeValue(forKey: oldest)
            }
            usage.queries[queryKey] = Activity.record(usage.queries[queryKey], at: now)
        }
        if results[id] == nil, results.count >= 512,
           let oldest = results.min(by: { ($0.value.activity?.date ?? .distantPast) < ($1.value.activity?.date ?? .distantPast) })?.key {
            results.removeValue(forKey: oldest)
        }
        results[id] = usage
    }

    public mutating func reset(id: String) { results.removeValue(forKey: id) }

    func scores(for id: String, queryKey: String?, at now: Date) -> (query: Double, overall: Double) {
        guard let usage = results[id] else { return (0, 0) }
        let query = queryKey.flatMap { usage.queries[$0] }?.score(at: now) ?? 0
        return (query, usage.activity?.score(at: now) ?? 0)
    }
}
