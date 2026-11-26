import Foundation

/// M1 composition uses the existing source verifier, seal and protected registry.
/// It deliberately offers no execution capability; M2 must supply live leases.
package final class MacOSStoreBuildInstallationService: RaycastStoreInstallationService, @unchecked Sendable {
    package var buildTarget: RaycastStoreBuildDependencies.Target { .macOSArm64 }
    private let profile: MacOSBuildProfile
    private let coordinator: MacOSExtensionBuild.Coordinator
    private let seal: RaycastStoreArtifactSeal
    package init(profile: MacOSBuildProfile) throws {
        self.profile = profile
        let builder = try MacOSSignedBuildService(profile: profile)
        coordinator = try .init(expected: profile.configuration.recipe, service: builder)
        seal = try .init(publicKey: profile.publicKey, recipe: profile.sealRecipe)
    }
    package func qualifiedAPIVersions() async throws -> Set<String> { try profile.verify(); return [] }
    package func build(project: RaycastStoreBuildProject, source: RaycastStoreSource, installationID: UUID) async throws -> RaycastStoreInstallCoordinator.BuiltArtifact {
        try profile.verify()
        guard project.source == source, project.target == .macOSArm64, project.runtimeAPIVersion == nil,
              let manifestBytes = project.files.first(where: { $0.path == "package.json" })?.body else { throw MacOSExtensionBuild.Failure.project }
        let manifest = try RaycastExtensionManifest.readStoreManifest(manifestBytes, files: Set(project.files.map(\.path)))
        guard manifest.name == source.slug else { throw MacOSExtensionBuild.Failure.project }
        let plan = try MacOSExtensionBuild.Plan(files: project.files.map { .init(path: $0.path, body: $0.body) }, entries: manifest.commands.map(\.entry))
        let artifact = try await coordinator.build(plan) { [profile] in try profile.verify(); return true }
        try Task.checkCancellation()
        let recipe = try profile.sealRecipe
        let projectDigest = try StoreRuntimeBridge.projectDigest(entry: manifest.commands[0].entry,
            files: project.files.map { .init(path: $0.path, body: $0.body) })
        let built: [StoreRuntimeBridge.BuiltCommand] = artifact.commands.map { file in
            .init(receipt: .init(provenance: .init(installation: .init(id: installationID.uuidString, generation: 0),
                entry: file.path, projectDigest: projectDigest, runtimeDigest: recipe.runtimeDigest), artifactDigest: MacOSExtensionBuild.hash(file.body)), artifact: file.body)
        }
        return try seal.issue(source: source, installationID: installationID, project: project, built: built,
                                    capabilities: [], buildArtifact: artifact, sign: { [profile] in try profile.sign($0) })
    }
    package func verify(bytes: Data, source: RaycastStoreSource, installationID: UUID) throws -> RaycastStoreTrustedDescription {
        try profile.verify(); return try seal.verify(bytes: bytes, source: source, installationID: installationID)
    }
    package func verifyRegistryAccess() throws { try profile.verify() }
    package func quarantine(installationID: UUID, before generation: UInt64) throws {
        // M1 has no runtime admission or active instance. There is nothing to
        // stop; this must be replaced with M2's single live generation authority.
        try profile.verify()
    }
    package func revoke(installationID: UUID, before generation: UInt64) async throws { try profile.verify() }
    package func readiness(_ context: RaycastStoreInstallCoordinator.RunContext) async throws -> RaycastStoreLaunchReadiness { .runtimeUnavailable }
    package func runCurrent(_ context: RaycastStoreInstallCoordinator.RunContext) async throws { throw RaycastStoreInstaller.Failure.launchBlocked }

    package static func open(id: UUID, application: Bundle, hostIdentifier: String = "org.keylane.launcher") async throws -> RaycastStoreInstallCoordinator {
        let profile = try MacOSBuildProfile.open(id: id, application: application, hostIdentifier: hostIdentifier)
        let backend = try RaycastStoreInstallCoordinator(root: profile.root, service: Self(profile: profile), anchor: profile.anchor, requiresExistingRoot: true)
        _ = try await backend.recoverPendingPublication()
        try await backend.verifyExistingProtectedRegistry()
        return backend
    }
}
