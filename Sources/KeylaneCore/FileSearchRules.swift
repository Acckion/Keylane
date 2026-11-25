import Foundation
import Darwin

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
    /// Suggested roots only; the controller watches/indexes each one after it
    /// has been picked or granted. Separate cloud roots avoid watching Library.
    public static func recommendedScopes(home: String) -> Self {
        var options = Self(roots: [
            home + "/Desktop", home + "/Documents", home + "/Downloads", "/Applications",
            home + "/Library/Mobile Documents/com~apple~CloudDocs",
            home + "/Library/CloudStorage",
        ])
        options.enabled = false
        // These defaults suggest CloudStorage explicitly. A blanket ignore
        // would otherwise silently discard its children even after authorization.
        options.ignorePatterns.removeAll { $0 == "**/Library/CloudStorage/**" }
        return options
    }

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
    public static let defaultIgnores = ["*.tmp", "*.temp", "node_modules", "__pycache__", "**/tmp/**", "**/temp/**", "**/[Cc]ache/**", "**/[Cc]aches/**", "**/Library/Application Support/**", "**/Mobile Documents/**/PreferenceSync/**", "**/Mobile Documents/**/Application Support/**", "**/Library/CloudStorage/**", "**/.claude/worktrees/**", "**/.codex/worktrees/**", "**/.cursor/worktrees/**", "**/.gemini/worktrees/**", "**/.windsurf/worktrees/**", "**/.local/share/opencode/worktree/**", "**/conductor/workspaces/**", "**/.raycast/worktrees/**", "**/.git/**"]
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
    private static func ignoreData(root: Int32, name: String) -> Data? {
        // Borrow the root until a child descriptor is opened; the caller keeps
        // it alive for the whole synchronous read. Missing files need no dup.
        var fd = root
        var ownsDescriptor = false
        defer { if ownsDescriptor { close(fd) } }
        let components = name.split(separator: "/")
        for (offset, component) in components.enumerated() {
            let last = offset == components.count - 1
            if last {
                var info = stat()
                guard fstatat(fd, String(component), &info, AT_SYMLINK_NOFOLLOW) == 0,
                      info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= 262_144 else { return nil }
            }
            let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (last ? 0 : O_DIRECTORY)
            let next = openat(fd, String(component), flags)
            guard next >= 0 else { return nil }
            if ownsDescriptor { close(fd) }
            fd = next; ownsDescriptor = true
        }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= 262_144 else { return nil }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; return nil }
            if count == 0 { break }
            guard data.count + count <= 262_144 else { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { return nil }
        return data
    }
    public static func readIgnoreRules(in directory: URL) -> [IgnoreRule] {
        let base = directory.path
        guard directory.isFileURL, base.hasPrefix("/"), !base.contains("\0") else { return [] }
        // Avoid Foundation's per-child resourceValues and implicit URL directory
        // probes. Pin the caller-authorized directory (including explicit root aliases);
        // reject special files and links within the rule-file paths.
        let root = Darwin.open(base, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK)
        guard root >= 0 else { return [] }
        defer { close(root) }
        return [".gitignore", ".ignore", ".rayignore", ".git/info/exclude"].flatMap { name -> [IgnoreRule] in
            guard let data = ignoreData(root: root, name: name), let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(whereSeparator: \.isNewline).compactMap { line in
                let value = line.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty, !value.hasPrefix("#"), value.count <= 1024 else { return nil }
                return IgnoreRule(base: base, line: value)
            }
        }
    }
}
