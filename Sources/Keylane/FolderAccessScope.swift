import Foundation
import Darwin

struct ScreenshotScope: Codable, Identifiable, Equatable {
    let path: String
    let bookmark: Data?
    var id: String { path }
    var accessibleURL: URL? {
        let original = URL(fileURLWithPath: path, isDirectory: true)
        let url: URL
        if let bookmark {
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: bookmark,
                                          options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                          relativeTo: nil, bookmarkDataIsStale: &stale),
                  !stale, resolved.standardizedFileURL.path == original.standardizedFileURL.path else { return nil }
            url = resolved
        } else {
            url = original
        }

        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        guard let directory = opendir(url.path) else { return nil }
        closedir(directory)
        return url
    }
}
