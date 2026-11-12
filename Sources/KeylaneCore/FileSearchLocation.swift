import Darwin
import Foundation

public enum FileDirectorySort: String, CaseIterable, Sendable {
    case name, created, modified

    public var title: String {
        switch self {
        case .name: "名称"
        case .created: "创建时间"
        case .modified: "修改时间"
        }
    }
}

public struct FileSearchLocation {
    public enum Failure: LocalizedError {
        case outsideScope, excluded, scopeRoot

        public var errorDescription: String? {
            switch self {
            case .outsideScope: "路径不在已授权的文件搜索范围内。"
            case .excluded: "此路径已被文件搜索规则排除。"
            case .scopeRoot: "请在设置中移除搜索范围根目录。"
            }
        }
    }

    private let options: FileSearchOptions
    private let roots: [(configured: String, resolved: String)]
    private let exclusions: [String]
    private let restored: Set<String>
    private let ignoresFile: (String, String) -> Bool
    private let ignoresFolder: (String, String) -> Bool
    private var rulesByParent: [String: [FileSearchRules.IgnoreRule]] = [:]

    public init(options: FileSearchOptions, automaticExclusions: [String], restored: Set<String> = []) {
        self.options = options
        self.restored = restored
        roots = options.roots.map {
            let path = Self.normalizedPath($0)
            return (path, Self.canonicalPath(path) ?? path)
        }.sorted { max($0.configured.count, $0.resolved.count) > max($1.configured.count, $1.resolved.count) }
        exclusions = (options.excludedPaths + automaticExclusions).flatMap { path in
            [path, Self.canonicalPath(path) ?? path]
        }
        ignoresFile = FileSearchRules.pathFilter(options.ignorePatterns)
        ignoresFolder = FileSearchRules.pathFilter(options.ignorePatterns, directory: true)
    }

    public static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    public static func typedURL(_ text: String) -> URL? {
        guard !text.contains("\0"), text.hasPrefix("/") || text == "~" || text.hasPrefix("~/") else { return nil }
        return URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
    }

    public static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func normalizedPath(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
            } else if component != "." { components.append(component) }
        }
        return "/" + components.joined(separator: "/")
    }

    private mutating func check(_ url: URL, directory: Bool, root: String) throws {
        let path = url.path
        if exclusions.contains(where: { Self.contains(path, in: $0) }) { throw Failure.excluded }
        guard path != root else { return }
        let homeLibrary = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        var ancestors = [url]
        while let last = ancestors.last {
            let parent = last.deletingLastPathComponent()
            if parent.path == root { break }
            ancestors.append(parent)
        }
        for item in ancestors.reversed() {
            let name = item.lastPathComponent
            let folder = item.path == path ? directory : true
            let ignored = folder ? ignoresFolder : ignoresFile
            let inherited = options.useIgnoreFiles ? rules(in: item.deletingLastPathComponent(), root: root) : []
            if (!options.includeHidden && name.hasPrefix(".")) || ignored(item.path, name)
                || FileSearchRules.ignored(item, directory: folder, patterns: [], rules: inherited)
                || (folder && item.path == homeLibrary)
                || (folder && [".build", "DerivedData", "node_modules"].contains(name) && !restored.contains(item.path))
                || (folder && item.pathExtension.lowercased() == "app" && item.path != path) {
                throw Failure.excluded
            }
        }
    }

    private mutating func rules(in directory: URL, root: String) -> [FileSearchRules.IgnoreRule] {
        let key = root + "\0" + directory.path
        if let cached = rulesByParent[key] { return cached }
        let inherited = directory.path == root ? [] : rules(in: directory.deletingLastPathComponent(), root: root)
        let combined = inherited + FileSearchRules.readIgnoreRules(in: directory)
        rulesByParent[key] = combined
        return combined
    }

    public mutating func item(at url: URL) throws -> SpotlightFile {
        try itemWithCreationDate(at: url).file
    }

    private mutating func itemWithCreationDate(at url: URL) throws -> (file: SpotlightFile, created: Date) {
        let path = Self.normalizedPath(url.path)
        guard let root = roots.first(where: { Self.contains(path, in: $0.configured) || Self.contains(path, in: $0.resolved) }) else {
            throw Failure.outsideScope
        }
        let prefix = Self.contains(path, in: root.configured) ? root.configured : root.resolved
        let relative = path.dropFirst(prefix.count).drop(while: { $0 == "/" })
        let entry = URL(fileURLWithPath: root.configured).appendingPathComponent(String(relative))
        guard let resolvedPath = Self.canonicalPath(entry.path) else {
            if let error = POSIXErrorCode(rawValue: errno) { throw POSIXError(error) }
            throw CocoaError(.fileReadUnknown)
        }
        guard let resolvedRoot = roots.first(where: { Self.contains(resolvedPath, in: $0.resolved) }) else { throw Failure.outsideScope }
        let resolved = URL(fileURLWithPath: resolvedPath)
        let values = try resolved.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey, .creationDateKey,
            .contentModificationDateKey, .volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsInternalKey])
        let directory = values.isDirectory == true
        guard FileManager.default.isReadableFile(atPath: resolved.path) else { throw CocoaError(.fileReadNoPermission) }
        try check(entry, directory: directory, root: root.configured)
        if resolved.path != entry.path { try check(resolved, directory: directory, root: resolvedRoot.resolved) }
        if !options.externalVolumes && (values.volumeIsLocal == false || values.volumeIsRemovable == true || values.volumeIsInternal == false) {
            throw Failure.excluded
        }
        return (.init(url: entry, name: entry.lastPathComponent, modified: values.contentModificationDate ?? .distantPast,
                      isDirectory: directory, contentType: values.contentType), values.creationDate ?? .distantPast)
    }

    public mutating func children(of directory: URL, sortedBy sort: FileDirectorySort,
                                  isCancelled: () -> Bool = { false }) throws -> [SpotlightFile] {
        let folder = try item(at: directory)
        guard folder.isDirectory else { throw CocoaError(.fileReadUnknown) }
        let entries = try FileManager.default.contentsOfDirectory(at: folder.url, includingPropertiesForKeys: nil,
                                                                   options: options.includeHidden ? [] : [.skipsHiddenFiles])
        var items: [(file: SpotlightFile, created: Date)] = []
        for entry in entries {
            if isCancelled() { return [] }
            if let item = try? itemWithCreationDate(at: entry) { items.append(item) }
        }
        items.sort { lhs, rhs in
            if sort == .created, lhs.created != rhs.created { return lhs.created > rhs.created }
            if sort == .modified, lhs.file.modified != rhs.file.modified { return lhs.file.modified > rhs.file.modified }
            let order = lhs.file.name.localizedStandardCompare(rhs.file.name)
            return order == .orderedSame ? lhs.file.id < rhs.file.id : order == .orderedAscending
        }
        return items.prefix(200).map(\.file)
    }
}
