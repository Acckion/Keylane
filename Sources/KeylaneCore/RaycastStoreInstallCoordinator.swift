import Foundation

/// Implemented only by the app-owned signed guest and broker composition.
/// The same authority verifies persisted artifacts, admits a fresh run, and
/// revokes previous generations. Catalogue or app UI data cannot select it.
public protocol RaycastStoreInstallationService: RaycastStoreArtifactTrust {
    var buildTarget: RaycastStoreBuildDependencies.Target { get }
    func qualifiedAPIVersions() async throws -> Set<String>
    func build(project: RaycastStoreBuildProject, source: RaycastStoreSource, installationID: UUID) async throws
        -> RaycastStoreInstallCoordinator.BuiltArtifact
    func readiness(_ context: RaycastStoreInstallCoordinator.RunContext) async throws -> RaycastStoreLaunchReadiness
    /// Atomically admit with the live broker's generation and preference/capability
    /// authority, before starting the guest. A prior readiness call is not authority.
    /// A revocation completed before this call must forbid this generation even
    /// when the VM has not yet started; later revocation stops its active session.
    func runCurrent(_ context: RaycastStoreInstallCoordinator.RunContext) async throws
}
extension RaycastStoreInstallationService {
    public var buildTarget: RaycastStoreBuildDependencies.Target { .linuxArm64 }
}

/// The common Store backend. Its only executable boundary is the injected
/// app-owned service; there is no alternate host runner or fixture fallback.
public actor RaycastStoreInstallCoordinator: RaycastStoreBackend, RaycastStorePreferencePersistence {
    public struct BuiltArtifact: Sendable {
        public let bytes: Data
        public let digest: String
        public let capabilities: Set<String>

        public init(bytes: Data, digest: String, capabilities: Set<String>) {
            self.bytes = bytes
            self.digest = digest
            self.capabilities = capabilities
        }
    }

    public struct RunContext: Sendable {
        public let installation: RaycastStoreInstallation
        public let commandID: String
        public let artifact: RaycastStoreDiskRegistry.LaunchArtifact
        let registry: RaycastStoreDiskRegistry
        let arguments: [String: String]

        init(installation: RaycastStoreInstallation, commandID: String, artifact: RaycastStoreDiskRegistry.LaunchArtifact,
             registry: RaycastStoreDiskRegistry, arguments: [String: String] = [:]) {
            self.installation = installation
            self.commandID = commandID
            self.artifact = artifact
            self.registry = registry
            self.arguments = arguments
        }
    }

    private let registry: RaycastStoreDiskRegistry
    private let service: any RaycastStoreInstallationService
    private let acquireProject: @Sendable (RaycastStoreSource, Set<String>) async throws -> RaycastStoreBuildProject
    private let validateSource: @Sendable (RaycastStoreSource) throws -> Void
    private var building: Set<String> = []

    public init(root: URL, service: any RaycastStoreInstallationService, anchor: any RaycastStoreRegistryAnchor) throws {
        try self.init(root: root, service: service, anchor: anchor, requiresExistingRoot: false)
    }

    package init(root: URL, service: any RaycastStoreInstallationService, anchor: any RaycastStoreRegistryAnchor,
                 requiresExistingRoot: Bool, preferenceVault: MacOSReviewedPreferenceVault? = nil) throws {
        self.service = service
        registry = try RaycastStoreDiskRegistry(root: root, trust: service, anchor: anchor,
                                              requiresExistingRoot: requiresExistingRoot, preferenceVault: preferenceVault)
        validateSource = { _ in }
        acquireProject = { source, versions in
            let catalog = RaycastPublicCatalog()
            let package = try await catalog.prepareSource(source)
            return try await catalog.prepareBuildProject(package, supportedRuntimeAPIVersions: versions, target: service.buildTarget)
        }
    }

    package init(root: URL, service: any RaycastStoreInstallationService,
         anchor: (any RaycastStoreRegistryAnchor)? = nil, requiresExistingRoot: Bool = false,
         validateSource: @escaping @Sendable (RaycastStoreSource) throws -> Void = { _ in },
         acquireProject: @escaping @Sendable (RaycastStoreSource, Set<String>) async throws -> RaycastStoreBuildProject) throws {
        self.service = service
        registry = try RaycastStoreDiskRegistry(root: root, trust: service, anchor: anchor,
                                              requiresExistingRoot: requiresExistingRoot)
        self.validateSource = validateSource
        self.acquireProject = acquireProject
    }

    package func verifyExistingProtectedRegistry() async throws {
        try await registry.verifyExistingProtectedRegistry()
    }
    public func recoverPendingPublication() async throws -> RaycastStoreDiskRegistry.PublicationRecovery {
        try await registry.recoverPendingPublication()
    }
    public func recoverInterruptedMutation() async throws { _ = try await registry.recoverPendingPublication() }

    public func prepare(_ source: RaycastStoreSource) async throws -> RaycastStorePreparedArtifact {
        try await prepare(source, replacing: nil)
    }
    public func prepareUpdate(_ source: RaycastStoreSource, replacing expected: RaycastStoreInstallation) async throws -> RaycastStorePreparedArtifact {
        try await prepare(source, replacing: expected)
    }
    private func prepare(_ source: RaycastStoreSource, replacing expected: RaycastStoreInstallation?) async throws -> RaycastStorePreparedArtifact {
        try validateSource(source)
        let key = source.slug.lowercased()
        guard building.insert(key).inserted else { throw RaycastStoreInstaller.Failure.busy }
        defer { building.remove(key) }
        let before = try await registry.installations().first { $0.source.slug == source.slug }
        if let expected {
            guard expected.source.slug == source.slug, Self.sameInstallation(before, expected) else { throw RaycastStoreDiskRegistry.Failure.stale }
        } else if before != nil { throw RaycastStoreInstaller.Failure.existingDifferentRevision }
        let versions = try await service.qualifiedAPIVersions()
        if let recovered = try await registry.stagedArtifact(for: source) { return recovered }
        try Task.checkCancellation()
        let project = try await acquireProject(source, versions)
        if let api = project.runtimeAPIVersion, !versions.contains(api) { throw RaycastStoreInstaller.Failure.invalidArtifact }
        try Task.checkCancellation()
        let existing = try await registry.installations().first { $0.source.slug == source.slug }
        guard Self.sameInstallation(before, existing) else { throw RaycastStoreDiskRegistry.Failure.stale }
        let id = existing?.id ?? UUID()
        let built = try await service.build(project: project, source: source, installationID: id)
        try Task.checkCancellation()
        try validateSource(source)
        let current = try await registry.installations().first { $0.source.slug == source.slug }
        guard Self.sameInstallation(before, current) else { throw RaycastStoreDiskRegistry.Failure.stale }
        return try await registry.prepare(bytes: built.bytes, expectedDigest: built.digest, source: source,
                                          grantedCapabilities: built.capabilities, installationID: id)
    }
    private static func sameInstallation(_ lhs: RaycastStoreInstallation?, _ rhs: RaycastStoreInstallation?) -> Bool {
        switch (lhs,rhs) {
        case (nil,nil): return true
        case (.some(let a), .some(let b)): return a.id == b.id && a.source == b.source && a.generation == b.generation && a.enabled == b.enabled && a.pendingOperation == b.pendingOperation
        default: return false
        }
    }

    public func install(_ artifact: RaycastStorePreparedArtifact) async throws -> RaycastStoreInstallation {
        try Task.checkCancellation()
        return try await registry.activate(artifact)
    }

    public func installations() async throws -> [RaycastStoreInstallation] {
        try await registry.installations()
    }

    public func installation(for slug: String) async throws -> RaycastStoreInstallation? {
        try await installations().first { $0.source.slug == slug }
    }

    /// Implements the UI persistence seam with the same registry authority.
    public func load(installationID: UUID, generation: UInt64) async throws -> RaycastStorePreferenceSnapshot {
        try await registry.load(installationID: installationID, generation: generation)
    }

    public func save(installationID: UUID, generation: UInt64, changes: RaycastStorePreferenceChanges) async throws {
        try await registry.save(installationID: installationID, generation: generation, changes: changes)
    }

    public func setEnabled(installationID: UUID, enabled: Bool) async throws -> RaycastStoreInstallation {
        let receipt = try await installation(id: installationID)
        return try await registry.setEnabled(installationID: installationID, expectedGeneration: receipt.generation, enabled: enabled)
    }

    public func uninstall(installationID: UUID) async throws {
        let receipt = try await installation(id: installationID)
        try await registry.uninstall(installationID: installationID, expectedGeneration: receipt.generation)
    }

    public func launchReadiness(installationID: UUID, commandID: String) async throws -> RaycastStoreLaunchReadiness {
        do {
            let context = try await runContext(installationID: installationID, commandID: commandID)
            return try await service.readiness(context)
        } catch RaycastStoreDiskRegistry.Failure.inactive {
            return .runtimeUnavailable
        }
    }

    public func launch(installationID: UUID, commandID: String) async throws {
        let context = try await runContext(installationID: installationID, commandID: commandID)
        try Task.checkCancellation()
        try await service.runCurrent(context)
    }

    /// Invoke the generation represented by the Launcher declaration. An update
    /// must never turn a shortcut for an old declaration into a different run.
    package func launch(_ installation: RaycastStoreInstallation, commandID: String, arguments: [String: String] = [:]) async throws {
        let artifact = try await registry.validate(installationID: installation.id, generation: installation.generation,
                                                   commandID: commandID, capabilities: [])
        try Task.checkCancellation()
        try await service.runCurrent(.init(installation: installation, commandID: commandID, artifact: artifact, registry: registry, arguments: arguments))
    }

    private func installation(id: UUID) async throws -> RaycastStoreInstallation {
        guard let value = try await installations().first(where: { $0.id == id }) else {
            throw RaycastStoreDiskRegistry.Failure.missing
        }
        return value
    }

    private func runContext(installationID: UUID, commandID: String) async throws -> RunContext {
        let receipt = try await installation(id: installationID)
        // This verifies the artifact and command; the actual capability lease is
        // minted only in runCurrent by the same authority that handles revoke.
        let artifact = try await registry.validate(installationID: installationID, generation: receipt.generation,
                                                   commandID: commandID, capabilities: [])
        return .init(installation: receipt, commandID: commandID, artifact: artifact, registry: registry)
    }
}
