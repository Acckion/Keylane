import CryptoKit
import Foundation

/// Package composition only. A future product composition must provide the
/// app-owned profile/broker authority and signed engine; this is not a provider
/// or a switch for enabling the production Store.
package struct RaycastStoreSignedInstallationService: RaycastStoreInstallationService {
    package enum Failure: Error, Equatable {
        case runtime, identity, preferences, capabilities
    }

    package struct Admission: Sendable {
        let launchID = UUID()
        let profileID: UUID
        let commandID: String
        let installation: StoreRuntimeBridge.Installation
        let artifact: StoreRuntimeBridge.Receipt
        let capabilities: Set<String>
        let launchContext: StoreGuestLaunchContext
    }

    package struct Lease: Sendable {
        /// The app-owned driver must use the same live state for request effects,
        /// cancellation and preference lookup, including before VM startup.
        let isCurrent: @Sendable () -> Bool
        let finish: @Sendable () -> Void
    }

    package protocol Authority: Sendable {
        func buildCapabilities(profileID: UUID, manifest: RaycastExtensionManifest) throws -> Set<String>
        func permits(_ admission: Admission) throws -> Bool
        /// Atomically check profile/generation/watermark and bind a lease. No
        /// suspension, nested registry access or entry point selected by content.
        func admit(_ admission: Admission) throws -> Lease
        /// Return only after older leases are revoked and active guest stops are
        /// confirmed; otherwise the registry remains quarantined.
        func verifyRegistryAccess(profileID: UUID) throws
        func quarantine(profileID: UUID, installationID: UUID, before generation: UInt64) throws
        func revoke(profileID: UUID, installationID: UUID, before generation: UInt64) async throws
    }

    struct Artifacts: Sendable {
        let verify: @Sendable (Data, RaycastStoreSource, UUID) throws -> RaycastStoreTrustedDescription
        let open: @Sendable (RaycastStoreDiskRegistry.LaunchArtifact, RaycastStoreInstallation, String) throws -> RaycastStoreArtifactSeal.RunArtifact
        let issue: @Sendable @MainActor (RaycastStoreSource, UUID, RaycastStoreBuildProject, [StoreRuntimeBridge.BuiltCommand], Set<String>) throws -> RaycastStoreInstallCoordinator.BuiltArtifact
    }

    private let profileID: UUID
    private let recipe: RaycastStoreArtifactSeal.Recipe
    private let authority: any Authority
    private let engine: any StoreRuntimeBridge.IsolatedEngine & Sendable
    private let artifacts: Artifacts

    /// The signed engine's driver must already be composed with this same
    /// authority (live lease, broker effects and stop confirmation). No normal
    /// product constructs this adapter before that composition is available.
    package init(profileID: UUID, recipe: RaycastStoreArtifactSeal.Recipe, publicKey: P256.Signing.PublicKey,
                 sign: @escaping @Sendable @MainActor (Data) throws -> P256.Signing.ECDSASignature,
                 engine: StoreSignedGuestEngine, authority: any Authority) throws {
        let seal = try RaycastStoreArtifactSeal(publicKey: publicKey, recipe: recipe)
        self.init(profileID: profileID, recipe: recipe, engine: engine, authority: authority,
                  artifacts: .init(verify: { try seal.verify(bytes: $0, source: $1, installationID: $2) },
                    open: { try seal.open($0, installation: $1, commandID: $2) },
                    issue: { try seal.issue(source: $0, installationID: $1, project: $2, built: $3, capabilities: $4, sign: sign) }))
    }

    // Module-internal deterministic inert fixtures; not normal app composition.
    init(profileID: UUID, recipe: RaycastStoreArtifactSeal.Recipe, engine: any StoreRuntimeBridge.IsolatedEngine & Sendable,
         authority: any Authority, artifacts: Artifacts) {
        self.profileID = profileID
        self.recipe = recipe
        self.authority = authority
        self.engine = engine
        self.artifacts = artifacts
    }

    @MainActor private func preflight() throws {
        guard try engine.verifiedRuntimeDigest() == recipe.runtimeDigest else { throw Failure.runtime }
    }

    package func qualifiedAPIVersions() async throws -> Set<String> {
        try await preflight()
        return recipe.qualifiedAPIVersions
    }

    @MainActor package func build(project: RaycastStoreBuildProject, source: RaycastStoreSource,
                                  installationID: UUID) async throws -> RaycastStoreInstallCoordinator.BuiltArtifact {
        try preflight()
        guard project.source == source,
              project.runtimeAPIVersion.map(recipe.qualifiedAPIVersions.contains) ?? true,
              let metadata = project.files.first(where: { $0.path == "package.json" }) else { throw Failure.identity }
        let files = Set(project.files.map(\.path))
        let manifest = try RaycastExtensionManifest.readStoreManifest(metadata.body, files: files)
        guard manifest.name == source.slug, RaycastPublicCatalog.declaresMacOS(manifest.platforms) else { throw Failure.identity }
        let grants = try authority.buildCapabilities(profileID: profileID, manifest: manifest)
        let installation = StoreRuntimeBridge.Installation(id: installationID.uuidString, generation: 0)
        let bridge = StoreRuntimeBridge(engine: engine) { candidate, operation in
            operation == .stagingBuild && candidate == installation
        }
        let inputs = project.files.map { StoreRuntimeBridge.File(path: $0.path, body: $0.body) }
        var built: [StoreRuntimeBridge.BuiltCommand] = []
        for command in manifest.commands {
            try Task.checkCancellation()
            built.append(try await bridge.prepare(installation: installation, entry: command.entry, files: inputs))
        }
        try preflight()
        return try artifacts.issue(source, installationID, project, built, grants)
    }

    package func verify(bytes: Data, source: RaycastStoreSource, installationID: UUID) throws -> RaycastStoreTrustedDescription {
        try artifacts.verify(bytes, source, installationID)
    }

    package func verifyRegistryAccess() throws {
        try authority.verifyRegistryAccess(profileID: profileID)
    }

    package func quarantine(installationID: UUID, before generation: UInt64) throws {
        try authority.quarantine(profileID: profileID, installationID: installationID, before: generation)
    }

    package func revoke(installationID: UUID, before generation: UInt64) async throws {
        try await authority.revoke(profileID: profileID, installationID: installationID, before: generation)
    }

    package func readiness(_ context: RaycastStoreInstallCoordinator.RunContext) async throws -> RaycastStoreLaunchReadiness {
        do { try await preflightLaunch() } catch { return .runtimeUnavailable }
        do {
            return try await context.registry.withCurrentRun(context) { installation, trusted, snapshot in
                let (request, _) = try admission(context, installation, trusted, snapshot)
                return try authority.permits(request) ? .ready : .capabilityDenied
            }
        } catch Failure.preferences { return .preferencesRequired }
        catch Failure.capabilities { return .capabilityDenied }
    }

    @MainActor private func preflightLaunch() throws {
        try preflight()
        guard engine.supportsTicketedLaunch else { throw Failure.runtime }
    }

    @MainActor package func runCurrent(_ context: RaycastStoreInstallCoordinator.RunContext) async throws {
        try preflightLaunch()
        let (request, artifact, lease) = try await context.registry.withCurrentRun(context) { installation, trusted, snapshot in
            try Task.checkCancellation()
            let (request, artifact) = try admission(context, installation, trusted, snapshot)
            return (request, artifact, try authority.admit(request))
        }
        defer { lease.finish() }
        guard lease.isCurrent() else { throw StoreRuntimeBridge.Rejection.staleInstallation }
        let bridge = StoreRuntimeBridge(engine: engine) { candidate, operation in
            operation == .enabledRun && candidate == request.installation && lease.isCurrent()
        }
        let ticket = StoreGuestRunTicket(id: request.launchID, profileID: request.profileID, installation: request.installation,
            receipt: request.artifact, commandID: request.commandID, capabilities: request.capabilities,
            launchContext: request.launchContext, liveLease: lease.isCurrent)
        try await bridge.run(artifact: artifact.bytes, ticket: ticket)
    }

    private func admission(_ context: RaycastStoreInstallCoordinator.RunContext, _ installation: RaycastStoreInstallation,
                           _ trusted: RaycastStoreTrustedDescription, _ snapshot: RaycastStorePreferenceSnapshot) throws
        -> (Admission, RaycastStoreArtifactSeal.RunArtifact) {
        guard installation.enabled, installation.id == context.installation.id, installation.generation > 0,
              trusted.extensionID == installation.source.slug, snapshot.storedSecretKeys.isEmpty,
              let command = trusted.manifest.commands.first(where: { $0.id == context.commandID }) else { throw Failure.identity }
        // No argument-provider or host file/path broker is admitted in this slice.
        guard command.arguments.isEmpty else { throw Failure.capabilities }
        let schema = try RaycastStorePreferenceSchema(manifest: trusted.manifest, commandID: command.id)
        guard schema.validate(snapshot: snapshot).isEmpty else { throw Failure.preferences }
        var preferences: [String: StoreGuestLaunchContext.OrdinaryPreference] = [:]
        for entry in schema.entries {
            guard ["textfield", "checkbox", "dropdown"].contains(entry.field.type) else {
                if entry.field.required == true { throw Failure.preferences }
                continue
            }
            guard let value = schema.value(for: entry, snapshot: snapshot) else { continue }
            guard preferences[entry.id.name] == nil else { throw Failure.preferences }
            switch value {
            case .string(let text): preferences[entry.id.name] = .text(text)
            case .bool(let flag): preferences[entry.id.name] = .toggle(flag)
            case .application: throw Failure.preferences
            }
        }
        guard preferences.isEmpty || trusted.requiredCapabilities.contains("preferences.read") else { throw Failure.capabilities }
        let launch = StoreGuestLaunchContext(ordinaryPreferences: preferences)
        do { _ = try launch.preferencesReply() } catch { throw Failure.preferences }
        let artifact = try artifacts.open(context.artifact, installation, command.id)
        guard artifact.receipt.provenance.installation.id == installation.id.uuidString,
              artifact.receipt.provenance.installation.generation == 0,
              artifact.receipt.provenance.runtimeDigest == recipe.runtimeDigest,
              artifact.receipt.provenance.entry == command.entry else { throw Failure.identity }
        return (.init(profileID: profileID, commandID: command.id, installation: .init(id: installation.id.uuidString, generation: installation.generation),
                      artifact: artifact.receipt, capabilities: trusted.requiredCapabilities, launchContext: launch), artifact)
    }
}


extension RaycastStoreSignedInstallationService.Authority {
    package func verifyRegistryAccess(profileID: UUID) throws {}
    package func quarantine(profileID: UUID, installationID: UUID, before generation: UInt64) throws {}
}
