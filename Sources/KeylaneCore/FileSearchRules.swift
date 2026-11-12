import Foundation

public struct FileSearchOptions: Codable, Equatable {
    public var roots: [String]
    public var ignorePatterns: [String]
    public var excludedPaths: [String] = []
    public var searchFromLauncher = false
    public var contentSearch = false
    public var includeHidden = false
    public var useIgnoreFiles = true
    public var externalVolumes = true
    public var keepRemovedVolumes = true
    public var enforceDiskSpace = false
    public var enabled = true
    public init(roots: [String]) { self.roots = roots; ignorePatterns = Self.defaultIgnores }
    private enum CodingKeys: String, CodingKey { case roots, ignorePatterns, excludedPaths, searchFromLauncher, contentSearch, includeHidden, useIgnoreFiles, externalVolumes, keepRemovedVolumes, enforceDiskSpace, enabled }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(roots: try values.decode([String].self, forKey: .roots))
        ignorePatterns = try values.decodeIfPresent([String].self, forKey: .ignorePatterns) ?? Self.defaultIgnores
        excludedPaths = try values.decodeIfPresent([String].self, forKey: .excludedPaths) ?? []
        searchFromLauncher = try values.decodeIfPresent(Bool.self, forKey: .searchFromLauncher) ?? false
        contentSearch = try values.decodeIfPresent(Bool.self, forKey: .contentSearch) ?? false
        includeHidden = try values.decodeIfPresent(Bool.self, forKey: .includeHidden) ?? false
        useIgnoreFiles = try values.decodeIfPresent(Bool.self, forKey: .useIgnoreFiles) ?? true
        externalVolumes = try values.decodeIfPresent(Bool.self, forKey: .externalVolumes) ?? true
        keepRemovedVolumes = try values.decodeIfPresent(Bool.self, forKey: .keepRemovedVolumes) ?? true
        enforceDiskSpace = try values.decodeIfPresent(Bool.self, forKey: .enforceDiskSpace) ?? false
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
    public static let defaultIgnores = ["*.tmp", "*.temp", "node_modules", "**/tmp/**", "**/temp/**", "**/[Cc]ache/**", "**/[Cc]aches/**", "**/Library/Application Support/**", "**/Mobile Documents/**/PreferenceSync/**", "**/Mobile Documents/**/Application Support/**", "**/Library/CloudStorage/**", "**/.claude/worktrees/**", "**/.codex/worktrees/**", "**/.cursor/worktrees/**", "**/.gemini/worktrees/**", "**/.windsurf/worktrees/**", "**/.local/share/opencode/worktree/**", "**/conductor/workspaces/**", "**/.raycast/worktrees/**", "**/.git/**"]
}
public enum FileSearchRules {
    private static let globCache: NSCache<NSString, NSRegularExpression> = { let value = NSCache<NSString, NSRegularExpression>(); value.countLimit = 512; return value }()
    public static func rank(_ name: String, query: String) -> Int {
        ranker(for: query)(name)
    }
    static func ranker(for query: String) -> (String) -> Int {
        let phrase = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let words = tokens(phrase)
        return { name in
            let name = fold(name)
            if name == phrase { return 1000 }
            if name.hasPrefix(phrase) { return 800 }
            if name.contains(phrase) { return 600 }
            return words.allSatisfy { name.contains($0) } ? 500 : 0
        }
    }
    /// Prepare regexes once per query or scan and reuse ranges across rules.
    public static func pathFilter(_ patterns: [String], directory: Bool = false) -> (String, String) -> Bool {
        let filters: [(regex: NSRegularExpression, basename: Bool)] = patterns.compactMap { pattern in
            guard let glob = compileGlob(pattern, directory: directory) else { return nil }
            return glob
        }
        return { path, name in
            let subject = directory ? path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" : path
            let pathRange = NSRange(location: 0, length: subject.utf16.count)
            let nameRange = NSRange(location: 0, length: name.utf16.count)
            return filters.contains { filter in
                filter.regex.firstMatch(in: filter.basename ? name : subject,
                                        range: filter.basename ? nameRange : pathRange) != nil
            }
        }
    }
    public static func tokens(_ query: String) -> [String] {
        Array(query.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).map(String.init).prefix(16))
    }
    public static func fold(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public static func contains(_ name: String, query: String) -> Bool {
        let haystack = fold(name); let words = tokens(query)
        return !words.isEmpty && words.allSatisfy { haystack.contains(fold($0)) }
    }
    /// Shell glob syntax only: no shell execution, expansion or arbitrary regex.
    public static func glob(_ pattern: String, matches path: String, directory: Bool = false) -> Bool {
        guard let glob = compileGlob(pattern, directory: directory) else { return false }
        let path = directory ? path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" : path
        let subject = glob.basename ? URL(fileURLWithPath: path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lastPathComponent : path
        return glob.regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
    }

    private static func compileGlob(_ pattern: String, directory: Bool) -> (regex: NSRegularExpression, basename: Bool)? {
        let original = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, original.utf8.count <= 1024 else { return nil }
        let directoryOnly = original.hasSuffix("/")
        if directoryOnly && !directory { return nil }
        let value = directoryOnly ? String(original.dropLast()) : original
        let basename = !value.contains("/")
        let cacheKey = ((directory ? "d:" : "f:") + original) as NSString
        if let expression = globCache.object(forKey: cacheKey) { return (expression, basename) }
        let chars = Array(value); var regex = ""; var i = 0
        while i < chars.count {
            let char = chars[i]
            if char == "*" {
                if i + 1 < chars.count, chars[i+1] == "*" {
                    if i+2 < chars.count, chars[i+2] == "/" { regex += "(?:.*/)?"; i += 3; continue }
                    regex += ".*"; i += 2; continue
                }
                regex += "[^/]*"
            } else if char == "?" { regex += "[^/]" }
            else if char == "[", let close = chars[(i+1)...].firstIndex(of: "]"), close-i <= 32 {
                let content = String(chars[(i+1)..<close])
                // Limit character classes to simple letters/digits/ranges.
                if content.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) { regex += "[" + content + "]"; i = close }
                else { regex += "\\[" }
            } else { regex += NSRegularExpression.escapedPattern(for: String(char)) }
            i += 1
        }
        if directory { regex += "/?" }
        guard let expression = try? NSRegularExpression(pattern: "^(?:" + regex + ")$") else { return nil }
        globCache.setObject(expression, forKey: cacheKey)
        return (expression, basename)
    }
    public struct IgnoreRule {
        public let base: String
        public let pattern: String
        public let negated: Bool
        public init(base: String, line: String) {
            self.base = base
            let escaped = line.hasPrefix("\\!") || line.hasPrefix("\\#")
            negated = !escaped && line.hasPrefix("!")
            pattern = escaped || negated ? String(line.dropFirst()) : line
        }
    }
    public static func ignored(_ url: URL, directory: Bool, patterns: [String], rules: [IgnoreRule]) -> Bool {
        let path = url.path
        if patterns.contains(where: { glob($0, matches: path, directory: directory) }) { return true }
        var ignored = false
        for rule in rules {
            guard path.hasPrefix(rule.base + "/") else { continue }
            let relative = String(path.dropFirst(rule.base.count + 1))
            let anchored = rule.pattern.hasPrefix("/")
            let pattern = anchored ? String(rule.pattern.dropFirst()) : rule.pattern
            if anchored && !pattern.trimmingCharacters(in:CharacterSet(charactersIn:"/")).contains("/") && relative.contains("/") { continue }
            if glob(pattern, matches: relative, directory: directory) { ignored = !rule.negated }
        }
        return ignored
    }
    public static func readIgnoreRules(in directory: URL) -> [IgnoreRule] {
        [".gitignore", ".ignore", ".rayignore", ".git/info/exclude"].flatMap { name -> [IgnoreRule] in
            let url = directory.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey,.isSymbolicLinkKey]), values.isSymbolicLink != true, (values.fileSize ?? 0) <= 262144,
                  let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(whereSeparator: \.isNewline).compactMap { line in
                let value = line.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty, !value.hasPrefix("#"), value.count <= 1024 else { return nil }
                return IgnoreRule(base: directory.path, line: value)
            }
        }
    }
}
