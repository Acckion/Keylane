import Foundation

public struct ApplicationLeftovers {
    public struct Item {
        public var url: URL { target.url }
        fileprivate let target: FileResultOperations.Target
    }

    /// Probe only paths owned by the complete bundle identifier. Shared locations
    /// and names that merely contain the identifier are outside this search.
    public static func find(bundleIdentifier: String, in library: URL) -> [Item] {
        guard !bundleIdentifier.isEmpty, !bundleIdentifier.hasPrefix("."), !bundleIdentifier.hasSuffix("."),
              !bundleIdentifier.contains(".."),
              bundleIdentifier.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46
              }),
              let home = FileSearchLocation.canonicalPath(library.deletingLastPathComponent().path) else { return [] }
        let root = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(library.lastPathComponent)
        let id = bundleIdentifier
        let locations = [
            ("Application Support", id), ("Caches", id), ("Containers", id),
            ("Preferences", id + ".plist"), ("Saved Application State", id + ".savedState"),
            ("Logs", id), ("WebKit", id), ("HTTPStorages", id),
            ("HTTPStorages", id + ".binarycookies"), ("Cookies", id + ".binarycookies"),
            ("Application Scripts", id)
        ]
        return locations.compactMap { folder, name in
            let url = root.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(name)
            guard let target = try? FileResultOperations.target(for: url), target.canonicalPath == url.path else { return nil }
            return Item(target: target)
        }
    }

    public static func trash(_ item: Item) throws {
        try FileResultOperations.trash(item.target)
    }
}
