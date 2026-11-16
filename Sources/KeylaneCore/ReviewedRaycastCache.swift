import Foundation

public struct ReviewedRaycastCache {
    public static let maximumBytes = 4_096
    private static let maximumEntries = 64
    private static let maximumEncodedBytes = maximumBytes + 2 * maximumEntries

    private let file: URL

    public init(installationImage: URL) {
        file = installationImage.deletingLastPathComponent().appendingPathComponent("cache.json")
    }

    public func load() -> [[String]] {
        guard let attributes = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              attributes.isRegularFile == true, attributes.isSymbolicLink == false,
              let size = attributes.fileSize, size <= Self.maximumEncodedBytes,
              let data = try? Data(contentsOf: file), data.count <= Self.maximumEncodedBytes else { return [] }
        let decoder = JSONDecoder()
        let entries: [[String]]
        if let ordered = try? decoder.decode([[String]].self, from: data) {
            entries = ordered
        } else if let legacy = try? decoder.decode([String: String].self, from: data) {
            entries = legacy.sorted { $0.key < $1.key }.map { [$0.key, $0.value] }
        } else {
            return []
        }
        return (try? Self.encode(entries)) != nil ? entries : []
    }

    public func save(_ entries: [[String]]) throws {
        try Self.encode(entries).write(to: file, options: .atomic)
    }

    public func remove() throws {
        do {
            try FileManager.default.removeItem(at: file)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    private static func encode(_ entries: [[String]]) throws -> Data {
        guard entries.count <= maximumEntries else { throw CocoaError(.fileWriteOutOfSpace) }
        var values: [String: String] = [:]
        for entry in entries {
            guard entry.count == 2 else { throw CocoaError(.fileWriteInvalidFileName) }
            let key = entry[0]
            let value = entry[1]
            guard key.utf8.count <= 1_550, value.utf8.count <= 2_048, values[key] == nil,
                  let parts = try? JSONDecoder().decode([String].self, from: Data(key.utf8)),
                  parts.count == 2, parts.allSatisfy({ $0.utf8.count <= 128 })
            else { throw CocoaError(.fileWriteInvalidFileName) }
            values[key] = value
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let compact = try encoder.encode(values)
        guard compact.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        return try encoder.encode(entries)
    }
}
