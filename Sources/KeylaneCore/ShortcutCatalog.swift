import Foundation

public struct SystemShortcut: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public var commandID: String { "shortcut:" + id }

    public static func parse(_ output: String) -> [Self] {
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasSuffix(")"), let separator = line.range(of: " (", options: .backwards),
                  let identifier = UUID(uuidString: String(line[separator.upperBound..<line.index(before: line.endIndex)])) else { return nil }
            let name = String(line[..<separator.lowerBound])
            guard !name.isEmpty, seen.insert(identifier.uuidString).inserted else { return nil }
            return Self(id: identifier.uuidString, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
