import Darwin
import Foundation

/// The only native adapter for the fixed signed builder. No manifest path, argv,
/// npm command, PATH lookup, fixture evaluator or runtime fallback is accepted.
package final class MacOSSignedBuildService: MacOSExtensionBuild.Service, @unchecked Sendable {
    private final class Gate: @unchecked Sendable { let lock = NSLock(); var active = false }
    private static let gate = Gate()
    private let profile: MacOSBuildProfile
    private let lock = NSLock()
    private var active: (UUID, MacOSOwnedHelperProcess)?
    private var cancelled: [UUID] = []
    package init(profile: MacOSBuildProfile) throws { try profile.verify(); self.profile = profile }
    package func verifiedRecipe() throws -> MacOSExtensionBuild.Recipe {
        try profile.verify(); return profile.configuration.recipe
    }
    package func cancel(_ id: UUID) {
        lock.withLock {
            if let active, active.0 == id { active.1.cancel() }
            else { cancelled.append(id); if cancelled.count > 64 { cancelled.removeFirst() } }
        }
    }
    package func compile(_ request: MacOSExtensionBuild.Request) async throws -> MacOSExtensionBuild.Reply {
        guard try verifiedRecipe() == request.recipe else { throw MacOSExtensionBuild.Failure.toolchainChanged }
        let session = MacOSOwnedHelperProcess()
        try Self.gate.lock.withLock {
            guard !Self.gate.active else { throw MacOSExtensionBuild.Failure.busy }; Self.gate.active = true
        }
        var registered = false
        defer { if !registered { Self.gate.lock.withLock { Self.gate.active = false } } }
        try lock.withLock {
            guard active == nil else { throw MacOSExtensionBuild.Failure.busy }
            if cancelled.contains(request.id) { cancelled.removeAll { $0 == request.id }; throw CancellationError() }
            active = (request.id, session)
        }
        registered = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { [self] in
                    let result = Result {
                        let buildLock = try profile.acquireBuildLock()
                        defer { flock(buildLock, LOCK_UN); close(buildLock) }
                        let bytes = try session.run(helper: profile.helper, input: request.encoded(),
                                                    timeout: .seconds(30), outputLimit: 20 * 1024 * 1024)
                        guard try verifiedRecipe() == request.recipe else { throw MacOSExtensionBuild.Failure.toolchainChanged }
                        let reply = try JSONDecoder().decode(MacOSExtensionBuild.Reply.self, from: bytes)
                        _ = try MacOSExtensionBuild.Artifact(request: request, reply: reply)
                        return reply
                    }
                    lock.withLock { active = nil }
                    Self.gate.lock.withLock { Self.gate.active = false }
                    continuation.resume(with: result)
                }
            }
        } onCancel: { session.cancel() }
    }

}
