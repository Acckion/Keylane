import Foundation

/// Presentation only. File identity and actions must continue to use real paths.
public enum FileDisplayPath {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    public static func parent(of path: String) -> String {
        format((path as NSString).deletingLastPathComponent)
    }

    public static func format(_ path: String, home: String? = nil) -> String {
        let home = home ?? Self.home
        let cloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if path == cloud { return "iCloud Drive" }
        if path.hasPrefix(cloud + "/") { return "iCloud Drive" + path.dropFirst(cloud.count) }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
