import Foundation

public struct Quicklink: Codable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public var template: String

    public init(id: String = "quicklink:" + UUID().uuidString, title: String, template: String) {
        self.id = id
        self.title = title
        self.template = template
    }
}

public struct QuicklinkTemplate {
    public struct Parameter: Identifiable, Equatable {
        public let id: String
        public let defaultValue: String?
    }

    public enum ValidationError: LocalizedError, Equatable {
        case invalidURL
        case invalidParameter
        case conflictingDefaults(String)
        case missingValue(String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL: "请输入包含主机名的 HTTP 或 HTTPS 链接。"
            case .invalidParameter: "参数格式应为 {名称} 或 {名称=默认值}，并放在路径、查询或片段中。"
            case let .conflictingDefaults(name): "参数「\(name)」定义了不同的默认值。"
            case let .missingValue(name): "请输入参数「\(name)」。"
            }
        }
    }

    private enum Part {
        case literal(String)
        case parameter(Parameter)
    }

    public let parameters: [Parameter]
    private let parts: [Part]
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public init(_ input: String) throws {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [Part] = []
        var parameters: [Parameter] = []
        var definitions: [String: Parameter] = [:]
        var remainder = input[...]
        while let start = remainder.firstIndex(of: "{") {
            let prefix = remainder[..<start]
            guard !prefix.contains("}"), let end = remainder[start...].firstIndex(of: "}") else {
                throw ValidationError.invalidParameter
            }
            parts.append(.literal(String(prefix)))
            let definition = remainder[remainder.index(after: start)..<end].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = definition.first.map(String.init), !name.isEmpty,
                  name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0) }) else {
                throw ValidationError.invalidParameter
            }
            let value = definition.count == 2 ? String(definition[1]) : nil
            guard value?.contains("{") != true else { throw ValidationError.invalidParameter }
            let parameter = Parameter(id: name, defaultValue: value)
            if let existing = definitions[name] {
                guard existing == parameter else { throw ValidationError.conflictingDefaults(name) }
            } else {
                definitions[name] = parameter
                parameters.append(parameter)
            }
            parts.append(.parameter(parameter))
            remainder = remainder[remainder.index(after: end)...]
        }
        guard !remainder.contains("}") else { throw ValidationError.invalidParameter }
        parts.append(.literal(String(remainder)))
        let authority = input.range(of: "://").map { input[$0.upperBound...].prefix { !"/?#".contains($0) } }
        if authority?.contains("{") == true { throw ValidationError.invalidParameter }
        self.parts = parts
        self.parameters = parameters
        _ = try url(values: Dictionary(uniqueKeysWithValues: parameters.map { ($0.id, "value") }))
    }

    public func url(values: [String: String] = [:]) throws -> URL {
        let expanded = try parts.map { part in
            switch part {
            case let .literal(text): return text
            case let .parameter(parameter):
                let input = values[parameter.id]
                guard let value = input.flatMap({ $0.isEmpty ? nil : $0 }) ?? parameter.defaultValue else {
                    throw ValidationError.missingValue(parameter.id)
                }
                return value.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? ""
            }
        }.joined()

        guard let components = URLComponents(string: expanded),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              let url = components.url else { throw ValidationError.invalidURL }
        return url
    }
}

public struct QuicklinkLibrary: Codable, Equatable {
    public static let storageKey = "quicklinkLibrary.v1"
    public static let legacyKey = "link"
    public static let legacyID = "quicklink"
    public var links: [Quicklink]

    public init(links: [Quicklink]) { self.links = links }

    public static func load(from defaults: UserDefaults) throws -> Self {
        if let stored = defaults.object(forKey: storageKey) {
            guard let data = stored as? Data else { throw CocoaError(.coderReadCorrupt) }
            let library = try JSONDecoder().decode(Self.self, from: data)
            let ids = library.links.map(\.id)
            guard Set(ids).count == ids.count,
                  ids.allSatisfy({ $0 == legacyID || $0.hasPrefix("quicklink:") }) else {
                throw CocoaError(.coderReadCorrupt)
            }
            return library
        }
        let legacy = legacyTemplate(from: defaults) ?? "https://github.com/Acckion/Keylane"
        let library = Self(links: [Quicklink(id: legacyID, title: "快捷链接", template: legacy)])
        try library.save(to: defaults)
        return library
    }

    public static func legacyTemplate(from defaults: UserDefaults) -> String? {
        defaults.string(forKey: legacyKey)?
            .replacingOccurrences(of: "{", with: "%7B")
            .replacingOccurrences(of: "}", with: "%7D")
    }

    public func save(to defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: Self.storageKey)
    }
}
