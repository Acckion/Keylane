import Foundation

public struct Quicklink: Codable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public var template: String
    public var usesDynamicPlaceholders: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, title, template, usesDynamicPlaceholders
        case storedTags = "tags", storedPinned = "pinned", storedHiddenFromRoot = "hiddenFromRoot"
    }

    private var storedTags: [String]?
    private var storedPinned: Bool?
    private var storedHiddenFromRoot: Bool?

    public var tags: [String] {
        get { storedTags ?? [] }
        set { storedTags = Self.normalizedTags(newValue) }
    }
    public var pinned: Bool {
        get { storedPinned ?? false }
        set { storedPinned = newValue }
    }
    public var hiddenFromRoot: Bool {
        get { storedHiddenFromRoot ?? false }
        set { storedHiddenFromRoot = newValue }
    }

    public func duplicate() -> Self {
        var copy = Quicklink(title: title, template: template)
        copy.tags = tags
        copy.usesDynamicPlaceholders = usesDynamicPlaceholders
        return copy
    }

    static func normalizedTags(_ input: [String]) -> [String] {
        var seen: Set<String> = []
        return input.compactMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && seen.insert(tagKey(value)).inserted ? value : nil
        }
    }

    public static func tagKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
    }

    public func preparedForEditing() -> Self {
        guard usesDynamicPlaceholders != true, !QuicklinkTemplate.isLocalInput(template) else { return self }
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
        case invalidLocalURL
        case invalidParameter
        case conflictingDefaults(String)
        case missingValue(String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL: "请输入网页、邮件链接或本地文件的绝对路径。"
            case .invalidLocalURL: "请输入本机 file:// 链接或绝对路径。文件链接不支持参数、查询或片段。"
            case .invalidParameter: "请在路径、查询或片段中输入有效的动态占位符或 {名称} 参数。"
            case let .conflictingDefaults(name): "参数「\(name)」定义了不同的默认值。"
            case let .missingValue(name): "请输入参数「\(name)」。"
            }
        }
    }

    public let parameters: [Parameter]
    private enum Target { case local(URL), template(DynamicTemplate.Plan) }
    private let target: Target

    public var localURL: URL? {
        if case .local(let url) = target { return url }
        return nil
    }

    public init(_ input: String, context: DynamicTemplate.Context = .init(), legacy: Bool = false) throws {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isLocalInput(input) {
            target = .local(try Self.localFileURL(input))
            parameters = []
            return
        }
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

        let planned: DynamicTemplate.Plan
        do { planned = try template.plan(context: context, allowMoreLegacyArguments: legacy) }
        catch DynamicTemplate.Failure.conflictingArgument(let name) { throw ValidationError.conflictingDefaults(name) }
        target = .template(planned)
        parameters = planned.arguments
    }

    public func url(values: [String: String] = [:]) throws -> URL {
        let plan: DynamicTemplate.Plan
        switch target {
        case .local(let url): return url
        case .template(let value): plan = value
        }
        let output: DynamicTemplate.Rendered
        do { output = try plan.resolve(values) }
        catch DynamicTemplate.Failure.missingArgument(let name) { throw ValidationError.missingValue(name) }
        return try Self.url(output.text, hasPlaceholders: !output.replacements.isEmpty)
    }

    fileprivate static func isLocalInput(_ input: String) -> Bool {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return input.hasPrefix("/") || input.lowercased().hasPrefix("file:")
    }

    private static func localFileURL(_ input: String) throws -> URL {
        let path: String
        if input.hasPrefix("/") {
            path = input
        } else {
            guard input.lowercased().hasPrefix("file://"),
                  let url = URL(string: input, encodingInvalidCharacters: false),
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.host?.isEmpty != false || parts.host?.lowercased() == "localhost",
                  parts.user == nil, parts.password == nil, parts.port == nil,
                  parts.query == nil, parts.fragment == nil,
                  !parts.percentEncodedPath.lowercased().contains("%2f"),
                  let decodedPath = parts.percentEncodedPath.removingPercentEncoding else {
                throw ValidationError.invalidLocalURL
            }
            path = decodedPath
        }
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.utf8.contains(0) else {
            throw ValidationError.invalidLocalURL
        }
        // Avoid filesystem probing when validating, editing or importing a link.
        return URL(fileURLWithPath: path, isDirectory: path.hasSuffix("/"))
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

    public var tags: [String] {
        Quicklink.normalizedTags(links.flatMap(\.tags)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func search(_ text: String, tag: String = "", aliases: [String: String] = [:]) -> [Quicklink] {
        let query = SearchRanker.Query(text)
        let matches = links.compactMap { link -> (link: Quicklink, score: Int)? in
            guard tag.isEmpty || link.tags.contains(where: { Quicklink.tagKey($0) == tag }) else { return nil }
            guard !query.isEmpty else { return (link, 0) }
            let names = [link.title, link.template] + link.tags + (aliases[link.id].map { [$0] } ?? [])
            return names.compactMap { SearchRanker.score(SearchRanker.prepareName($0), query: query) }.max()
                .map { (link, $0) }
        }
        return matches.sorted { lhs, rhs in
            if lhs.link.pinned != rhs.link.pinned { return lhs.link.pinned }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let title = lhs.link.title.localizedStandardCompare(rhs.link.title)
            return title == .orderedSame ? lhs.link.id < rhs.link.id : title == .orderedAscending
        }.map(\.link)
    }

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

/// Raycast-compatible name and link, with optional Keylane organization fields.
private struct QuicklinkExchange: Codable {
    let name: String
    let link: String
    let tags: [String]?
    let pinned: Bool?
    let hiddenFromRoot: Bool?
    let legacyTemplate: Bool?

    init(_ quicklink: Quicklink) {
        name = quicklink.title
        link = quicklink.template
        tags = quicklink.tags.isEmpty ? nil : quicklink.tags
        pinned = quicklink.pinned ? true : nil
        hiddenFromRoot = quicklink.hiddenFromRoot ? true : nil
        legacyTemplate = quicklink.usesDynamicPlaceholders == true ? nil : true
    }
}

extension QuicklinkLibrary {
    public struct Import {
        public let links: [Quicklink]
        public let duplicates: Int
    }

    public func importJSON(_ data: Data, context: DynamicTemplate.Context = .init()) throws -> Import {
        struct Identity: Hashable {
            let title: String
            let template: String

            init(_ title: String, _ template: String) {
                self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
                if QuicklinkTemplate.isLocalInput(trimmed) {
                    self.template = (try? QuicklinkTemplate(trimmed))?.localURL?.absoluteString ?? trimmed
                } else {
                    self.template = trimmed
                }
            }
        }
        let records = try JSONDecoder().decode([QuicklinkExchange].self, from: data)
        var seen = Set(links.map { Identity($0.title, $0.template) })
        var added: [Quicklink] = []
        for record in records {
            let identity = Identity(record.name, record.link)
            guard !identity.title.isEmpty else { throw CocoaError(.coderReadCorrupt) }
            guard seen.insert(identity).inserted else { continue }
            var link = Quicklink(title: identity.title, template: identity.template)
            link.tags = record.tags ?? []
            link.pinned = record.pinned ?? false
            link.hiddenFromRoot = record.hiddenFromRoot ?? false
            if record.legacyTemplate == true { link.usesDynamicPlaceholders = nil }
            _ = try link.parsedTemplate(context: context)
            added.append(link)
        }
        return Import(links: added, duplicates: records.count - added.count)
    }

    public func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(links.map(QuicklinkExchange.init))
    }
}
