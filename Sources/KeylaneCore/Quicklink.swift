import Foundation

public struct Quicklink: Codable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public var template: String
    public var usesDynamicPlaceholders: Bool?

    public func preparedForEditing() -> Self {
        guard usesDynamicPlaceholders != true else { return self }
        let migrated = DynamicTemplate(template, usage: .quicklink, legacyQuicklinkOnly: true).legacySyntaxMigration
        guard (try? QuicklinkTemplate(migrated)) != nil else { return self }

        var draft = self
        draft.template = migrated
        draft.usesDynamicPlaceholders = true
        return draft
    }

    public func parsedTemplate(context: DynamicTemplate.Context = .init()) throws -> QuicklinkTemplate {
        try QuicklinkTemplate(template, context: context, legacy: usesDynamicPlaceholders != true)
    }

    public init(id: String = "quicklink:" + UUID().uuidString, title: String, template: String) {
        self.id = id
        self.title = title
        self.template = template
        usesDynamicPlaceholders = true
    }
}

public struct QuicklinkTemplate {
    public typealias Parameter = DynamicTemplate.Argument

    public enum ValidationError: LocalizedError, Equatable {
        case invalidURL
        case invalidParameter
        case conflictingDefaults(String)
        case missingValue(String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL: "请输入 HTTP、HTTPS 或 mailto 邮件链接。"
            case .invalidParameter: "请在路径、查询或片段中输入有效的动态占位符或 {名称} 参数。"
            case let .conflictingDefaults(name): "参数「\(name)」定义了不同的默认值。"
            case let .missingValue(name): "请输入参数「\(name)」。"
            }
        }
    }

    public let parameters: [Parameter]
    private let plan: DynamicTemplate.Plan

    public init(_ input: String, context: DynamicTemplate.Context = .init(), legacy: Bool = false) throws {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = DynamicTemplate(input, usage: .quicklink, legacyQuicklinkArguments: true,
                                       legacyQuicklinkOnly: legacy)
        let probe = NSMutableString(string: input)
        for range in template.placeholderRanges.reversed() {
            probe.replaceCharacters(in: range, with: "value")
        }
        let sample = probe as String
        guard !sample.contains("{"), !sample.contains("}") else { throw ValidationError.invalidParameter }
        let authority = input.range(of: "://").map { input[$0.upperBound...].prefix { !"/?#".contains($0) } }
        guard authority?.contains("{") != true else { throw ValidationError.invalidParameter }
        _ = try Self.url(sample, hasPlaceholders: !template.placeholderRanges.isEmpty)

        do { plan = try template.plan(context: context, allowMoreLegacyArguments: legacy) }
        catch DynamicTemplate.Failure.conflictingArgument(let name) { throw ValidationError.conflictingDefaults(name) }
        parameters = plan.arguments
    }

    public func url(values: [String: String] = [:]) throws -> URL {
        let output: DynamicTemplate.Rendered
        do { output = try plan.resolve(values) }
        catch DynamicTemplate.Failure.missingArgument(let name) { throw ValidationError.missingValue(name) }
        return try Self.url(output.text, hasPlaceholders: !output.replacements.isEmpty)
    }

    private static func url(_ expanded: String, hasPlaceholders: Bool) throws -> URL {
        guard let components = URLComponents(string: expanded),
              let scheme = components.scheme?.lowercased() else { throw ValidationError.invalidURL }
        if scheme == "mailto", !hasPlaceholders, components.host == nil,
           components.query == nil, components.fragment == nil,
           let url = ClipboardCategory.emailURL(in: components.path) { return url }
        guard scheme == "https" || scheme == "http",
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
