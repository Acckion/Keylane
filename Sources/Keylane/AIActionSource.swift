import Foundation
import Combine
import KeylaneCore

/// A module owns the resolver and its source-version check. No business switch in the AI host.
struct AIActionSource {
    let moduleID: ModuleID
    let load: @MainActor () async throws -> AIActionContext
    let isCurrent: @MainActor (AIActionContext) async throws -> Bool
}

/// An inert, module-owned context directory. Search and body reads run only after invocation.
struct AIContextRegistration: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var available: () -> Bool = { true }
    var availabilityUpdates: AnyPublisher<Bool, Never>?
    let search: @MainActor (String) async throws -> [AIContextCandidate]
}

struct AIContextCandidate: Identifiable {
    let id: String
    let title: String
    let detail: String
    let source: AIActionSource
}

/// Separate human-readable output from the validated argument passed to a result command.
struct AIActionOutput {
    let text: String
    let commandArgument: String?
    init(_ text: String, commandArgument: String? = nil) { self.text = text; self.commandArgument = commandArgument }
}

// Resource identity and content versions are shared by actions and chat attachments.
// Resolving always requires the module-owned source, never a decoded resource URI.
extension AIActionSource {
    @MainActor func captureSnapshot(maximumBytes: Int = 32_000) async throws -> AIActionContext {
        let context = try await load()
        try Task.checkCancellation()
        try context.validate(maximumBytes: maximumBytes)
        guard try await isCurrent(context) else { throw AIActionError.staleSource }
        try Task.checkCancellation()
        return try recordSnapshot(context)
    }

    func recordSnapshot(_ context: AIActionContext) throws -> AIActionContext {
        let reference = try AIResourceReference(moduleID: moduleID, sourceID: context.sourceID)
        let snapshot = AIResourceSnapshot(reference: reference, revision: context.fingerprint, text: context.text)
        return .init(sourceID: context.sourceID, title: context.title, text: context.text,
                     fingerprint: context.fingerprint, resourceSnapshot: snapshot)
    }
}
