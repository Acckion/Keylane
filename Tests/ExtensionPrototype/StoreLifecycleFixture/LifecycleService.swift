import CryptoKit
import Foundation
import KeylaneCore

final class FixtureAnchorStorage: RaycastStoreProtectedReceiptStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func read() throws -> Data? { lock.withLock { data } }
    func compareAndSwap(expected: Data?, replacement: Data) throws -> Bool {
        lock.withLock {
            guard expected == data else { return false }
            data = replacement
            return true
        }
    }
}

enum FixtureFailure: Error { case invalid }

@MainActor final class FixtureAuthority {
    var staged: UUID?
    var running: StoreRuntimeBridge.Installation?
    var minimum: [UUID: UInt64] = [:]
    var configuration = RaycastStorePreferenceSnapshot()
    var launchContext: StoreGuestLaunchContext?
    var copyCount = 0
    var hudCount = 0
    var runEvents: [StoreGuestProcessDriver.Capability] = []
    var confirmedRunCount = 0
    var builtArtifactDigest: String?
    var buildCount = 0

    func isCurrent(_ identity: StoreRuntimeBridge.Installation) -> Bool {
        guard let id = UUID(uuidString: identity.id) else { return false }
        return launchContext != nil && running == identity && identity.generation >= minimum[id, default: 1]
    }
}

@MainActor final class LifecycleService: RaycastStoreInstallationService {
    nonisolated let seal: RaycastStoreArtifactSeal
    let authority: FixtureAuthority
    private let signer: P256.Signing.PrivateKey
    private let bridge: StoreRuntimeBridge

    init(seal: RaycastStoreArtifactSeal, signer: P256.Signing.PrivateKey, engine: StoreSignedGuestEngine, authority: FixtureAuthority) {
        self.seal = seal; self.signer = signer; self.authority = authority
        bridge = StoreRuntimeBridge(engine: engine) { identity, operation in
            if operation == .stagingBuild { return identity.generation == 0 && identity.id == authority.staged?.uuidString }
            return authority.isCurrent(identity)
        }
    }

    nonisolated func verify(bytes: Data, source: RaycastStoreSource, installationID: UUID) throws -> RaycastStoreTrustedDescription {
        try seal.verify(bytes: bytes, source: source, installationID: installationID)
    }
    func qualifiedAPIVersions() async throws -> Set<String> { [] }

    func build(project: RaycastStoreBuildProject, source: RaycastStoreSource, installationID: UUID) async throws
        -> RaycastStoreInstallCoordinator.BuiltArtifact {
        guard authority.staged == nil, source.slug == FixtureProject.slug else { throw FixtureFailure.invalid }
        authority.staged = installationID
        defer { authority.staged = nil }
        let built = try await bridge.prepare(installation: .init(id: installationID.uuidString, generation: 0), entry: "src/entry.ts",
                                             files: project.files.map { .init(path: $0.path, body: $0.body) })
        let issued = try seal.issue(source: source, installationID: installationID, project: project, built: [built],
                              capabilities: ["clipboardCopy", "hud", "preferencesRead"], sign: { try signer.signature(for: $0) })
        authority.builtArtifactDigest = built.receipt.artifactDigest
        authority.buildCount += 1
        return issued
    }

    func readiness(_ context: RaycastStoreInstallCoordinator.RunContext) async throws -> RaycastStoreLaunchReadiness {
        let item = context.installation
        guard item.generation >= authority.minimum[item.id, default: 1] else { return .runtimeUnavailable }
        let schema = try RaycastStorePreferenceSchema(manifest: item.manifest, commandID: context.commandID)
        return schema.validate(snapshot: authority.configuration).isEmpty ? .ready : .preferencesRequired
    }

    func runCurrent(_ context: RaycastStoreInstallCoordinator.RunContext) async throws {
        let item = context.installation
        guard authority.running == nil, item.generation >= authority.minimum[item.id, default: 1] else {
            throw FixtureFailure.invalid
        }
        let schema = try RaycastStorePreferenceSchema(manifest: item.manifest, commandID: context.commandID)
        guard schema.validate(snapshot: authority.configuration).isEmpty,
              let declaration = item.manifest.commands.first(where: { $0.id == context.commandID }),
              declaration.arguments.count == 1, declaration.arguments.first?.name == "token",
              declaration.arguments.first?.type == "text" else { throw FixtureFailure.invalid }
        var ordinary: [String: StoreGuestLaunchContext.OrdinaryPreference] = [:]
        for field in schema.entries {
            // Allow only known ordinary values. The optional password never
            // crosses the DTO, even as an empty placeholder.
            guard field.field.type != "password",
                  let value = schema.value(for: field, snapshot: authority.configuration) else { continue }
            switch (field.id.name, value) {
            case ("action", .string(let text)): ordinary[field.id.name] = .text(text)
            case ("uppercase", .bool(let flag)): ordinary[field.id.name] = .toggle(flag)
            default: throw FixtureFailure.invalid
            }
        }
        let command = try seal.open(context.artifact, installation: item, commandID: context.commandID)
        let identity = StoreRuntimeBridge.Installation(id: item.id.uuidString, generation: item.generation)
        authority.running = identity
        authority.launchContext = .init(arguments: ["token": "00112233445566778899aabbccddeeff"], ordinaryPreferences: ordinary)
        authority.runEvents = []
        defer { authority.running = nil; authority.launchContext = nil }
        try await bridge.run(artifact: command.bytes, expectedReceipt: command.receipt, installation: identity)
        guard authority.runEvents == [.clipboardCopy, .hud] else { throw FixtureFailure.invalid }
        authority.confirmedRunCount += 1
    }

    func revoke(installationID: UUID, before generation: UInt64) async throws {
        authority.minimum[installationID] = max(generation, authority.minimum[installationID, default: 1])
        // This fixture never claims an in-flight child stop it didn't observe.
        if authority.running?.id == installationID.uuidString { throw StoreGuestProcessDriver.Failure.childStopUnconfirmed }
    }
}
