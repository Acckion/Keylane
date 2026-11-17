import Darwin
import Foundation

public struct ReviewedRaycastCache {
    public static let maximumBytes = 32 * 1024
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
        try withLock {
            try Self.encode(entries).write(to: file, options: .atomic)
        }
    }

    public func merge(_ updated: [[String]], from baseline: [[String]]) throws {
        // Validate both arrays before indexing and retaining any keys from the guest snapshot.
        _ = try Self.encode(baseline)
        _ = try Self.encode(updated)
        let original = Dictionary(uniqueKeysWithValues: baseline.enumerated().map { ($0.element[0], $0.offset) })
        let retained = Set(updated.map { $0[0] })
        let removed = Set(original.keys).subtracting(retained)
        try withLock {
            var current = load().filter { !removed.contains($0[0]) }
            // Entries moved by get or set form a suffix. Keep concurrent values on read-only touches.
            var lastOriginalIndex = -1
            var touched = false
            for entry in updated {
                let index = original[entry[0]]
                let valueChanged = index.map { !baseline[$0][1].utf8.elementsEqual(entry[1].utf8) } ?? true
                if let index, index > lastOriginalIndex, !valueChanged, !touched {
                    lastOriginalIndex = index
                    continue
                }
                touched = true
                let changed = current.firstIndex { $0[0] == entry[0] }
                let latest = changed.map { current.remove(at: $0) }
                if valueChanged { current.append(entry) }
                else if let latest { current.append(latest) }
            }
            try Self.encode(current).write(to: file, options: .atomic)
        }
    }

    public func remove() throws {
        do {
            try withLock {
                try FileManager.default.removeItem(at: file)
            }
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    private func withLock(_ access: () throws -> Void) throws {
        let path = file.deletingPathExtension().appendingPathExtension("lock").path
        let lock = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if lock < 0, errno == ENOENT { throw CocoaError(.fileNoSuchFile) }
        guard lock >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(lock) }
        while flock(lock, LOCK_EX) != 0 {
            if errno != EINTR { throw CocoaError(.fileWriteUnknown) }
        }
        try access()
    }

    private static func encode(_ entries: [[String]]) throws -> Data {
        guard entries.count <= maximumEntries else { throw CocoaError(.fileWriteOutOfSpace) }
        var values: [String: String] = [:]
        for entry in entries {
            guard entry.count == 2 else { throw CocoaError(.fileWriteInvalidFileName) }
            let key = entry[0]
            let value = entry[1]
            guard key.utf8.count <= 1_550, value.utf8.count <= 16 * 1024, values[key] == nil,
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
