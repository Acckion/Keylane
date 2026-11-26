import CryptoKit
import Foundation

/// Bounded source inventory. The caller must resolve the subtree from the pinned
/// official commit; this validates the resulting inventory, not its provenance.
public struct RaycastStoreSnapshot: Sendable {
    public struct File: Equatable, Sendable {
        public let path: String
        public let byteCount: Int
        public let gitBlobSHA: String

        /// Git hashes the object header as well as its content.
        public func verifies(_ bytes: Data) -> Bool {
            guard bytes.count == byteCount else { return false }
            var hash = Insecure.SHA1()
            hash.update(data: Data("blob \(byteCount)\0".utf8))
            hash.update(data: bytes)
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            return actual == gitBlobSHA
        }
    }

    public enum Failure: Error, Equatable {
        case oversizedInventory
        case incompleteTree
        case wrongTree
        case unsupportedEntry(String)
        case unsafePath(String)
        case pathCollision(String)
        case invalidObject(String)
        case oversizedFile(String)
        case oversizedSnapshot
        case missingManifest
    }

    public let source: RaycastStoreSource
    public let files: [File]
    public let totalBytes: Int

    private struct Tree: Decodable {
        struct Entry: Decodable {
            let path: String
            let mode: String
            let type: String
            let sha: String
            let size: Int?
        }
        let sha: String
        let truncated: Bool
        let tree: [Entry]
    }

    /// Supply the bounded JSON body of GitHub's recursive tree endpoint for the
    /// chosen extension subtree, not the entire repository.
    public init(source: RaycastStoreSource, treeSHA: String, recursiveTreeJSON: Data) throws {
        guard recursiveTreeJSON.count <= 2 * 1024 * 1024 else { throw Failure.oversizedInventory }
        let tree = try JSONDecoder().decode(Tree.self, from: recursiveTreeJSON)
        guard !tree.truncated else { throw Failure.incompleteTree }
        guard RaycastStoreSource.validRevision(treeSHA), tree.sha == treeSHA else { throw Failure.wrongTree }
        guard tree.tree.count <= 2_048 else { throw Failure.oversizedInventory }
        var inventory: [File] = []
        var paths: Set<String> = []
        var directories: Set<String> = []
        var total = 0
        for entry in tree.tree {
            guard Self.isSafePath(entry.path) else { throw Failure.unsafePath(entry.path) }
            guard RaycastStoreSource.validRevision(entry.sha) else { throw Failure.invalidObject(entry.path) }
            let directory: Bool
            switch (entry.type, entry.mode) {
            case ("tree", "040000"): directory = true
            case ("blob", "100644"), ("blob", "100755"): directory = false
            default: throw Failure.unsupportedEntry(entry.path)
            }
            let key = Self.pathKey(entry.path)
            guard paths.insert(key).inserted else { throw Failure.pathCollision(entry.path) }
            if directory {
                directories.insert(entry.path)
            } else {
                guard let size = entry.size, size >= 0 else { throw Failure.invalidObject(entry.path) }
                let maxBytes = entry.path == "package.json" ? 1024 * 1024 : 8 * 1024 * 1024
                guard size <= maxBytes else { throw Failure.oversizedFile(entry.path) }
                guard size <= 32 * 1024 * 1024 - total else { throw Failure.oversizedSnapshot }
                total += size
                inventory.append(.init(path: entry.path, byteCount: size, gitBlobSHA: entry.sha))
            }
        }
        for entry in tree.tree {
            let parts = entry.path.split(separator: "/")
            if parts.count > 1, !directories.contains(parts.dropLast().joined(separator: "/")) {
                throw Failure.pathCollision(entry.path)
            }
        }
        guard inventory.contains(where: { $0.path == "package.json" }) else { throw Failure.missingManifest }
        self.source = source
        files = inventory.sorted { $0.path < $1.path }
        totalBytes = total
    }

    private static func pathKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func isSafePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.utf8.count <= 512, parts.count <= 16 else { return false }
        return parts.allSatisfy { part in
            let key = pathKey(String(part))
            return !part.isEmpty && part.utf8.count <= 255 && key != "." && key != ".." && key != ".git"
                && part.unicodeScalars.allSatisfy {
                    !CharacterSet.controlCharacters.contains($0) && $0 != "\\" && $0 != ":"
                }
        }
    }
}
