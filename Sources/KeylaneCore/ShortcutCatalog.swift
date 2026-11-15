import Foundation

public struct SystemShortcut: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public var commandID: String { "shortcut:" + id }

    public var identifierSuffix: String { String(id.prefix(8)) }

    public static func parse(_ output: String) -> [Self] {
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasSuffix(")"), let separator = line.range(of: " (", options: .backwards),
                  let identifier = UUID(uuidString: String(line[separator.upperBound..<line.index(before: line.endIndex)])) else { return nil }
            let name = String(line[..<separator.lowerBound])
            guard !name.isEmpty, seen.insert(identifier.uuidString).inserted else { return nil }
            return Self(id: identifier.uuidString, name: name)
        }.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
}

public struct SystemShortcutFolder: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let shortcutIDs: Set<String>

    public init(id: String, name: String, shortcutIDs: Set<String>) {
        self.id = id
        self.name = name
        self.shortcutIDs = shortcutIDs
    }

    public struct Section: Identifiable {
        public let id: String?
        public let name: String
        public let shortcuts: [SystemShortcut]
    }

    public static func sections(_ folders: [Self], shortcuts: [SystemShortcut]) -> [Section] {
        var folderByShortcut: [String: String] = [:]
        for folder in folders {
            for id in folder.shortcutIDs where folderByShortcut[id] == nil {
                folderByShortcut[id] = folder.id
            }
        }
        let groups = Dictionary(grouping: shortcuts) { folderByShortcut[$0.id] }
        var sections = folders.compactMap { folder -> Section? in
            guard let shortcuts = groups[folder.id] else { return nil }
            return Section(id: folder.id, name: folder.name, shortcuts: shortcuts)
        }
        if let unfiled = groups[nil] {
            sections.append(Section(id: nil, name: "未分类", shortcuts: unfiled))
        }
        return sections
    }
}
