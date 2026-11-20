import Foundation

/// A per-command launch request produced by the app after validation against
/// the installed manifest. It is not read from package files or process env.
public struct StoreGuestLaunchContext: Sendable {
    /// Ordinary preferences only. Password/secret preference fields must not
    /// be selected by the app for this DTO; there is no secret-store access.
    public enum OrdinaryPreference: Encodable, Sendable {
        case text(String), toggle(Bool), number(Double)

        public func encode(to encoder: any Encoder) throws {
            var single = encoder.singleValueContainer()
            switch self {
            case .text(let value): try single.encode(value)
            case .toggle(let value): try single.encode(value)
            case .number(let value): try single.encode(value)
            }
        }
    }

    public enum Rejection: Error { case bounds }
    public let arguments: [String: String]
    public let ordinaryPreferences: [String: OrdinaryPreference]

    public init(arguments: [String: String] = [:], ordinaryPreferences: [String: OrdinaryPreference] = [:]) {
        self.arguments = arguments
        self.ordinaryPreferences = ordinaryPreferences
    }

    func launchData(loadPreferences: Bool) throws -> Data {
        guard arguments.count <= 16, arguments.keys.allSatisfy(Self.validKey),
              arguments.values.allSatisfy({ $0.utf8.count <= 1024 }) else { throw Rejection.bounds }
        let value = GuestLaunch(version: 1, arguments: arguments, loadPreferences: loadPreferences)
        return try Self.boundedJSON(value)
    }

    func preferencesReply() throws -> String {
        guard ordinaryPreferences.count <= 32, ordinaryPreferences.keys.allSatisfy(Self.validKey),
              ordinaryPreferences.values.allSatisfy({ preference in
                switch preference {
                case .text(let value): return value.utf8.count <= 1024
                case .number(let value): return value.isFinite
                case .toggle: return true
                }
              }) else { throw Rejection.bounds }
        let value = PreferenceReply(preferences: ordinaryPreferences)
        return String(decoding: try Self.boundedJSON(value), as: UTF8.self)
    }

    private struct GuestLaunch: Encodable {
        let version: Int
        let arguments: [String: String]
        let loadPreferences: Bool
    }
    private struct PreferenceReply: Encodable {
        let preferences: [String: OrdinaryPreference]
    }

    private static func validKey(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64,
              !["__proto__", "constructor", "prototype"].contains(value) else { return false }
        return value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) ||
            (48...57).contains($0) || $0 == 95 || $0 == 45 }
    }

    private static func boundedJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(value)
        // Broker JSON-encodes preference replies again; keep plenty of headroom.
        guard json.count <= 4096 else { throw Rejection.bounds }
        return json
    }
}
