import Foundation

struct AIFileToolIndexSource: Sendable {
    let isCurrent: @MainActor @Sendable () -> Bool
    let search: @MainActor @Sendable (String, String) async throws -> [String]
}
