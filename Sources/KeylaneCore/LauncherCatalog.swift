import Foundation

public struct CatalogApplication: Identifiable {
    public let url: URL
    public let identity: ApplicationIdentity
    public var id: String { url.path }
}
public enum ApplicationCatalog {
    public static var defaultRoots: [String] { ["/Applications", "/System/Applications", "/System/Library/CoreServices/Applications", "/System/Cryptexes/App/System/Applications", NSHomeDirectory() + "/Applications"] }
    public static func scan(roots: [String], excluded: Set<String>, languages: [String] = Locale.preferredLanguages) -> [CatalogApplication] {
        var found: [String:CatalogApplication] = [:]
        for root in roots {
            let rootURL = URL(fileURLWithPath: root).standardizedFileURL
            guard let iterator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = iterator.nextObject() as? URL {
                guard url.pathExtension.lowercased() == "app" else { continue }
                iterator.skipDescendants()
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL
                guard !excluded.contains(url.path), !excluded.contains(canonical.path), found[canonical.path] == nil else { continue }
                found[canonical.path] = CatalogApplication(url: canonical, identity: ApplicationIdentity(url: canonical, preferredLanguages: languages))
            }
        }
        return found.values.sorted { $0.identity.displayName.localizedStandardCompare($1.identity.displayName) == .orderedAscending }
    }
}
public struct Shortcut: Codable, Equatable, Hashable {
    public var key: UInt32
    public var modifiers: UInt32
    public init(key: UInt32, modifiers: UInt32) { self.key = key; self.modifiers = modifiers }
    public var isValid: Bool { key < 128 && modifiers & (256 | 2048 | 4096) != 0 }
    public static let launcher = Shortcut(key: 49, modifiers: 2048)
}
public enum ShortcutValidation {
    public static func conflict(in bindings: [String:Shortcut]) -> String? {
        var seen: [Shortcut:String] = [:]
        for id in bindings.keys.sorted() {
            guard let shortcut = bindings[id], shortcut.isValid else { return "快捷键必须包含 Command、Option 或 Control。" }
            if shortcut.modifiers == 256 && Set<UInt32>([0,4,6,7,8,9,12,18,19,20,21,22,23,25,26,28,40,43]).contains(shortcut.key) { return "该快捷键保留给文本编辑或窗口内操作。" }
            if let other = seen[shortcut] { return "快捷键冲突：\(other) 与 \(id)" }
            seen[shortcut] = id
        }
        return nil
    }
}
public struct ModifierTapTracker {
    private var pressedAt: Double?
    private var releasedAt: Double?
    public init() {}
    public mutating func cancel() { pressedAt = nil; releasedAt = nil }
    public mutating func update(pressed: Bool, time: Double) -> Bool {
        if pressed { pressedAt = time; return false }
        guard let start = pressedAt, time - start <= 0.25 else { cancel(); return false }
        pressedAt = nil
        if let last = releasedAt, time - last <= 0.35 { releasedAt = nil; return true }
        releasedAt = time; return false
    }
}
public struct SearchResultRank {
    public var score: Int
    public var favorite: Bool
    public var uses: Int
    public var title: String
    public var id: String
    private let priority: Int
    private let relevanceBand: Int
    private let queryUsage: Double
    private let overallUsage: Double

    public init(score: Int, favorite: Bool, uses: Int, title: String, id: String,
                priority: Int = 0, relevanceBand: Int? = nil, queryUsage: Double = 0, overallUsage: Double = 0) {
        self.score = score
        self.favorite = favorite
        self.uses = uses
        self.title = title
        self.id = id
        self.priority = priority
        self.relevanceBand = relevanceBand ?? score
        self.queryUsage = queryUsage
        self.overallUsage = overallUsage
    }

    public func precedes(_ other: SearchResultRank) -> Bool {
        if priority != other.priority { return priority > other.priority }
        if relevanceBand != other.relevanceBand { return relevanceBand > other.relevanceBand }
        if favorite != other.favorite { return favorite }
        if queryUsage != other.queryUsage { return queryUsage > other.queryUsage }
        if overallUsage != other.overallUsage { return overallUsage > other.overallUsage }
        if score != other.score { return score > other.score }
        if uses != other.uses { return uses > other.uses }
        let result = title.localizedStandardCompare(other.title)
        return result == .orderedSame ? id < other.id : result == .orderedAscending
    }
}
public enum ArgumentParser {
    public enum Failure: Error { case unfinishedQuote }
    public static func parse(_ text: String) throws -> [String] {
        var arguments: [String] = []; var value = ""; var quote: Character?; var escaped = false; var started = false
        for char in text {
            if escaped { value.append(char); escaped = false; started = true; continue }
            if char == "\\" && quote != "'" { escaped = true; started = true; continue }
            if let active = quote { if char == active { quote = nil } else { value.append(char) }; continue }
            if char == "\"" || char == "'" { quote = char; started = true }
            else if char.isWhitespace { if started { arguments.append(value); value = ""; started = false } }
            else { value.append(char); started = true }
        }
        guard quote == nil && !escaped else { throw Failure.unfinishedQuote }
        if started { arguments.append(value) }; return arguments
    }
}
