import Foundation

/// Composes the fixed builder, protected registry and optional signed command runtime.
package final class MacOSStoreBuildInstallationService: RaycastStoreInstallationService, @unchecked Sendable {
    package var buildTarget: RaycastStoreBuildDependencies.Target { .macOSArm64 }
    private let profile: MacOSBuildProfile
    private let coordinator: MacOSExtensionBuild.Coordinator
    private let ownership: MacOSStoreOwnership
    private let admission = MacOSExtensionRunAdmission()
    private let driver: MacOSRestrictedNoViewDriver?
    private let seal: RaycastStoreArtifactSeal
    package init(profile: MacOSBuildProfile, deliver: MacOSNoViewCapabilities.Presenter? = nil) throws {
        self.profile = profile
        let ownership = try profile.acquireStoreOwnership()
        self.ownership = ownership
        driver = profile.runDriver(ownership: ownership, deliver: deliver)
        let builder = try MacOSSignedBuildService(profile: profile)
        coordinator = try .init(expected: profile.configuration.recipe, service: builder)
        seal = try .init(publicKey: profile.publicKey, recipe: profile.sealRecipe)
    }
    package func qualifiedAPIVersions() async throws -> Set<String> { try profile.verify(); return try profile.sealRecipe.qualifiedAPIVersions }
    package func build(project: RaycastStoreBuildProject, source: RaycastStoreSource, installationID: UUID) async throws -> RaycastStoreInstallCoordinator.BuiltArtifact {
        try profile.verify()
        let sealAPIVersions = try profile.sealRecipe.qualifiedAPIVersions
        guard project.source == source, project.target == .macOSArm64,
              project.runtimeAPIVersion.map(sealAPIVersions.contains) ?? true,
              let manifestBytes = project.files.first(where: { $0.path == "package.json" })?.body else { throw MacOSExtensionBuild.Failure.project }
        let manifest = try MacOSReviewedRaycastCommand.manifest(
            data: manifestBytes, files: Set(project.files.map(\.path)), source: source, apiVersion: project.runtimeAPIVersion)
        guard manifest.name == source.slug else { throw MacOSExtensionBuild.Failure.project }
        let capabilities = try project.runtimeAPIVersion.flatMap {
            try MacOSReviewedRaycastCommand.buildEntries(for: source, apiVersion: $0).first?.capabilities
        } ?? []
        if capabilities.contains(MacOSNoViewCapabilities.secretPreferences), profile.preferenceVault == nil {
            throw RaycastStoreInstaller.Failure.noRunnableCommands
        }
        if profile.configuration.runHelperSHA256 != nil,
           !manifest.commands.contains(where: { MacOSExtensionRunAdmission.supports(command: $0, manifest: manifest, capabilities: capabilities) }) {
            throw RaycastStoreInstaller.Failure.noRunnableCommands
        }
        let planFiles = project.files.map { MacOSExtensionBuild.File(path: $0.path, body: $0.body) }
        let entries = manifest.commands.map(\.entry)
        let plan = if MacOSReviewedViewSession.canRun(capabilities) {
            try MacOSReviewedRaycastViewAdapter.plan(files: planFiles, entries: entries)
        } else {
            try MacOSExtensionBuild.Plan(files: planFiles, entries: entries)
        }
        let artifact: MacOSExtensionBuild.Artifact
        do {
            artifact = try await coordinator.build(plan) { [profile] in try profile.verify(); return true }
        } catch MacOSOwnedHelperProcess.Failure.failed {
            throw RaycastStoreInstaller.Failure.buildFailed
        } catch MacOSExtensionBuild.Failure.response {
            throw RaycastStoreInstaller.Failure.buildFailed
        }
        try Task.checkCancellation()
        let recipe = try profile.sealRecipe
        let projectDigest = try StoreRuntimeBridge.projectDigest(entry: manifest.commands[0].entry,
            files: project.files.map { .init(path: $0.path, body: $0.body) })
        let built: [StoreRuntimeBridge.BuiltCommand] = artifact.commands.map { file in
            .init(receipt: .init(provenance: .init(installation: .init(id: installationID.uuidString, generation: 0),
                entry: file.path, projectDigest: projectDigest, runtimeDigest: recipe.runtimeDigest), artifactDigest: MacOSExtensionBuild.hash(file.body)), artifact: file.body)
        }
        return try seal.issue(source: source, installationID: installationID, project: project, built: built,
                                    capabilities: capabilities, buildArtifact: artifact, sign: { [profile] in try profile.sign($0) })
    }
    package func verify(bytes: Data, source: RaycastStoreSource, installationID: UUID) throws -> RaycastStoreTrustedDescription {
        try profile.verify(); return try seal.verify(bytes: bytes, source: source, installationID: installationID)
    }
    package func verifyRegistryAccess() throws { try profile.verify() }
    package func quarantine(installationID: UUID, before generation: UInt64) throws {
        try profile.verify()
        admission.quarantine(installationID: installationID, before: generation)
    }

    package func revoke(installationID: UUID, before generation: UInt64) async throws {
        await admission.revoke(installationID: installationID, before: generation)
        try profile.verify()
    }

    package func readiness(_ context: RaycastStoreInstallCoordinator.RunContext) async throws -> RaycastStoreLaunchReadiness {
        guard let driver else { return .runtimeUnavailable }
        return try await context.registry.withCurrentRun(context) { _, trusted, snapshot in
            guard MacOSExtensionRunAdmission.supports(commandID: context.commandID, trusted: trusted) else {
                return .capabilityDenied
            }
            do {
                _ = try MacOSExtensionRunAdmission.launchContext(commandID: context.commandID, trusted: trusted, snapshot: snapshot)
            } catch MacOSExtensionRunAdmission.Failure.preferencesRequired {
                return .preferencesRequired
            } catch MacOSExtensionRunAdmission.Failure.unsupportedCommand {
                return .capabilityDenied
            }
            guard driver.canDeliver(capabilities: trusted.requiredCapabilities) else { return .capabilityDenied }
            _ = try driver.verifiedHelper()
            return .ready
        }
    }

    package func runCurrent(_ context: RaycastStoreInstallCoordinator.RunContext) async throws {
        guard let driver else { throw RaycastStoreInstaller.Failure.launchBlocked }
        try await admission.start(context, profileID: profile.id, seal: seal, driver: driver)
    }

    package static func open(id: UUID, application: Bundle, hostIdentifier: String = "org.keylane.launcher",
                             deliver: MacOSNoViewCapabilities.Presenter? = nil,
                             requiresRuntime: Bool = false) async throws -> RaycastStoreInstallCoordinator {
        let profile = try MacOSBuildProfile.open(id: id, application: application, hostIdentifier: hostIdentifier)
        if requiresRuntime, profile.configuration.runHelperSHA256 == nil { throw MacOSBuildProfile.Failure.unavailable }
        let backend = try RaycastStoreInstallCoordinator(root: profile.root, service: Self(profile: profile, deliver: deliver), anchor: profile.anchor, requiresExistingRoot: true, preferenceVault: profile.preferenceVault)
        _ = try await backend.recoverPendingPublication()
        try await backend.verifyExistingProtectedRegistry()
        return backend
    }
}
