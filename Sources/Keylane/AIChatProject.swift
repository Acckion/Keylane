import Foundation

struct AIChatProject: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name = ""
    var symbol = "folder"
    var instructions = ""
    var directory: URL?
    var directoryBookmark: Data?

    var directoryURL: URL? {
        guard let directoryBookmark else { return directory }
        var stale = false
        return (try? URL(resolvingBookmarkData: directoryBookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                         relativeTo: nil, bookmarkDataIsStale: &stale)) ?? directory
    }
}
