import Foundation

public enum FileIndexExclusionPolicy {
    private static let generatedDirectories: Set<String> = [
        ".build", "deriveddata", "node_modules", ".venv"
    ]
    private static let changeCandidates: Set<String> = [
        "build", "output", "dist", "cache", "target"
    ]

    public static func isKnownCache(_ directory: URL) -> Bool {
        let name = directory.lastPathComponent.lowercased()
        let parent = directory.deletingLastPathComponent().lastPathComponent.lowercased()
        return generatedDirectories.contains(name)
            || (parent == ".cargo" && (name == "registry" || name == "global-cache"))
            || (name == ".npm" && directory.deletingLastPathComponent().path == FileManager.default.homeDirectoryForCurrentUser.path)
    }

    public static func changeCandidate(for path: String, scopes: [String], restored: Set<String>,
                                       includeHidden: Bool) -> String? {
        guard let scope = scopes.filter({ FileSearchLocation.contains(path, in: $0) }).max(by: { $0.count < $1.count }),
              path != scope,
              includeHidden || !path.dropFirst(scope.count).split(separator: "/").contains(where: { $0.hasPrefix(".") })
        else { return nil }

        var directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        while directory.path != scope && FileSearchLocation.contains(directory.path, in: scope) {
            if changeCandidates.contains(directory.lastPathComponent.lowercased()) {
                let containsProtectedPath = scopes.contains { FileSearchLocation.contains($0, in: directory.path) }
                    || restored.contains { FileSearchLocation.contains($0, in: directory.path)
                        || FileSearchLocation.contains(directory.path, in: $0) }
                return containsProtectedPath ? nil : directory.path
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}
