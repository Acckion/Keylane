import Foundation
import KeylaneCore

/// Explicit, cancellable single-note access. Tests inject a reader instead of touching Apple Notes.
final class AppleNotesAIRequestPool {
    private var active: [UUID: ExtensionProcessRequest] = [:]
    func insert(_ request: ExtensionProcessRequest) -> UUID { let id = UUID(); active[id] = request; return id }
    func remove(_ id: UUID) { active.removeValue(forKey: id) }
    func cancel() { for request in active.values { request.cancel() }; active = [:] }
}

struct AppleNotesAIReader {
    var requests = AppleNotesAIRequestPool()
    func cancel() { requests.cancel() }
    let available: @MainActor () -> Bool
    var read: @Sendable (String, ExtensionProcessRequest) throws -> String = { try AppleNotesAutomation.readText($0, request: $1) }
    var search: @Sendable (String, ExtensionProcessRequest) throws -> [AppleNoteResult] = { try AppleNotesAutomation.search($0, request: $1, titlesOnly: true) }

    @MainActor func text(_ id: String) async throws -> String {
        guard !id.isEmpty, id.utf8.count <= 4_096 else { throw AIActionError.invalidDefinition }
        guard available() else { throw AIActionError.unavailable }
        let request = ExtensionProcessRequest()
        let ticket = requests.insert(request)
        defer { requests.remove(ticket) }
        let reader = read
        let text = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { try reader(id, request) }.value
        } onCancel: { request.cancel() }
        try Task.checkCancellation()
        guard !request.isCancelled else { throw CancellationError() }
        guard available() else { throw AIActionError.unavailable }
        try AIActionContext(sourceID: id, title: "", text: text).validate(maximumBytes: 32_000)
        return text
    }
    @MainActor func directory(_ query: String) async throws -> [AppleNoteResult] {
        guard query.utf8.count <= 1_024 else { throw AIActionError.inputTooLarge }
        guard available() else { throw AIActionError.unavailable }
        let request = ExtensionProcessRequest()
        let ticket = requests.insert(request)
        defer { requests.remove(ticket) }
        let search = search
        let rows = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { try search(query, request) }.value
        } onCancel: { request.cancel() }
        try Task.checkCancellation()
        guard !request.isCancelled else { throw CancellationError() }
        guard available() else { throw AIActionError.unavailable }
        return Array(rows.prefix(60))
    }
    func source(id: String, title: String) -> AIActionSource {
        .init(moduleID: .init(rawValue: "keylane.apple-notes"), load: {
            .init(sourceID: id, title: title, text: try await text(id))
        }, isCurrent: { context in AIActionContext.digest(try await text(id)) == context.fingerprint })
    }
}
