import CryptoKit
import Foundation

/// One verified bootstrap capability. The UI cannot mix a backend and
/// preferences from different profiles or enable them independently.
package struct RaycastStoreAppCapability: Sendable {
    package let coordinator: RaycastStoreInstallCoordinator
    package let enrollmentScope: RaycastStoreReceiptEnrollment.Scope?

    #if DEBUG
    package private(set) var offlineFixture: OfflineFixture?
    #endif

    private init(coordinator: RaycastStoreInstallCoordinator,
                 enrollmentScope: RaycastStoreReceiptEnrollment.Scope? = nil) {
        self.coordinator = coordinator
        self.enrollmentScope = enrollmentScope
    }

    /// Read-only readiness for an already provisioned profile. Neither the
    /// bundle nor the caller's registry is repaired or created here.
    @MainActor package static func verifyExisting(
        application: Bundle, expectedTeam: String, recipe: RaycastStoreArtifactSeal.Recipe,
        registryRoot: URL, profileID: UUID, registryID: UUID, anchor: RaycastStoreProtectedReceiptState,
        publicKey: P256.Signing.PublicKey, ownerBinding: RaycastStoreProtectedReceiptState.OwnerBinding,
        grants: Set<String>,
        sign: @escaping @Sendable @MainActor (Data) throws -> P256.Signing.ECDSASignature,
        sink: @escaping (StoreGuestRunTicket, String, String) throws -> String
    ) async throws -> Self {
        let coordinator = try await StoreGuestCommonAuthority.installedCandidate(
            application: application, root: registryRoot, profileID: profileID, registryID: registryID,
            teamIdentifier: expectedTeam, recipe: recipe, publicKey: publicKey, anchor: anchor,
            ownerBinding: ownerBinding, grants: grants, sign: sign, sink: sink
        )
        return Self(coordinator: coordinator, enrollmentScope: anchor.enrollmentScope)
    }

    /// Only the strict readback reader can mint this typed identity. The
    /// coordinator still rechecks the exact owner inode and protected slot.
    @MainActor package static func verifySelected(
        _ selection: RaycastStoreSelectedProfileReader.Capability,
        application: Bundle, expectedTeam: String, recipe: RaycastStoreArtifactSeal.Recipe,
        storage: RaycastStoreSerializedReceiptStorage, publicKey: P256.Signing.PublicKey, grants: Set<String>,
        sign: @escaping @Sendable @MainActor (Data) throws -> P256.Signing.ECDSASignature,
        sink: @escaping (StoreGuestRunTicket, String, String) throws -> String
    ) async throws -> Self {
        let binding = selection.ownerBinding
        let root = URL(fileURLWithPath: binding.rootPath, isDirectory: true)
        guard storage.matchesEnrollment(directory: root, identity: selection.receiptLock) else {
            throw StoreGuestCommonAuthority.Failure.denied
        }
        let anchor = try RaycastStoreProtectedReceiptState(storage: storage, registryID: selection.scope.registryID,
            publicKey: publicKey, recipe: recipe, owner: binding)
        guard anchor.enrollmentScope == selection.scope else { throw StoreGuestCommonAuthority.Failure.denied }
        return try await verifyExisting(application: application, expectedTeam: expectedTeam, recipe: recipe,
            registryRoot: root, profileID: selection.profileID, registryID: selection.scope.registryID, anchor: anchor,
            publicKey: publicKey, ownerBinding: binding, grants: grants, sign: sign, sink: sink)
    }

}

#if DEBUG
extension RaycastStoreAppCapability {
    /// Debug-only immutable source. No URLs/fetchers, catalog fallback, or authority provisioning.
    package struct OfflineFixture: Sendable {
        fileprivate let project: RaycastStoreBuildProject
        package let index: RaycastPublicCatalog.Index
        private let manifest: RaycastPublicCatalog.Details

        package init(project: RaycastStoreBuildProject, expectedDigest: String) throws {
            guard Self.digest(project) == expectedDigest,
                  let manifestBytes = project.files.first(where: { $0.path == "package.json" })?.body
            else { throw RaycastStoreInstaller.Failure.invalidArtifact }
            let extensionManifest = try RaycastExtensionManifest.readStoreManifest(
                manifestBytes, files: Set(project.files.map(\.path))
            )
            guard extensionManifest.name == project.source.slug else { throw RaycastStoreInstaller.Failure.invalidArtifact }
            self.project = project
            index = .init(revision: project.source.revision, slugs: [project.source.slug])
            manifest = try JSONDecoder().decode(RaycastPublicCatalog.Details.self, from: manifestBytes)
        }

        package func details(slug: String, revision: String) throws -> RaycastPublicCatalog.Details {
            guard slug == project.source.slug, revision == project.source.revision else {
                throw RaycastStoreInstaller.Failure.invalidArtifact
            }
            return manifest
        }

        func makeCoordinator(root: URL, service: RaycastStoreSignedInstallationService,
                             anchor: any RaycastStoreRegistryAnchor) throws -> RaycastStoreInstallCoordinator {
            try RaycastStoreInstallCoordinator(root: RaycastStoreAppCapability.checkedTemporaryRoot(root),
                service: service, anchor: anchor, requiresExistingRoot: true, validateSource: { candidate in
                    guard candidate == project.source else { throw RaycastStoreInstaller.Failure.invalidArtifact }
                }, acquireProject: { _, _ in project })
        }

        package static func digest(_ project: RaycastStoreBuildProject) -> String {
            var hash = SHA256()
            func append(_ data: Data) {
                var size = UInt64(data.count).bigEndian
                withUnsafeBytes(of: &size) { hash.update(bufferPointer: $0) }
                hash.update(data: data)
            }
            for value in ["keylane-offline-fixture-v1", project.source.slug, project.source.revision,
                          project.runtimeAPIVersion ?? ""] { append(Data(value.utf8)) }
            for file in project.files {
                append(Data(file.path.utf8))
                append(file.body)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    /// This overload uses exactly the native ticket driver and profile owner;
    /// only the source and caller-owned disposable enrollment are test fixtures.
    @MainActor package static func verifyNativeOfflineFixture(
        _ fixture: OfflineFixture, application: Bundle, expectedTeam: String,
        recipe: RaycastStoreArtifactSeal.Recipe, registryRoot: URL,
        profileID: UUID, registryID: UUID, anchor: RaycastStoreProtectedReceiptState,
        ownerBinding: RaycastStoreProtectedReceiptState.OwnerBinding, publicKey: P256.Signing.PublicKey,
        sign: @escaping @Sendable @MainActor (Data) throws -> P256.Signing.ECDSASignature,
        sink: @escaping (StoreGuestRunTicket, String, String) throws -> String
    ) async throws -> Self {
        _ = try checkedTemporaryRoot(registryRoot)
        let coordinator = try await StoreGuestCommonAuthority.offlineInstalledCandidate(application: application,
            root: registryRoot, profileID: profileID, registryID: registryID, teamIdentifier: expectedTeam,
            recipe: recipe, publicKey: publicKey, anchor: anchor, ownerBinding: ownerBinding,
            grants: ["feedback.toast", "preferences.read"], sign: sign, sink: sink, fixture: fixture)
        var capability = Self(coordinator: coordinator)
        capability.offlineFixture = fixture
        return capability
    }

    fileprivate static func checkedTemporaryRoot(_ root: URL) throws -> URL {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let canonical = root.resolvingSymlinksInPath()
        guard root.isFileURL, canonical.deletingLastPathComponent().path == temporary.path,
              canonical.lastPathComponent == root.lastPathComponent else {
            throw RaycastStoreInstaller.Failure.invalidArtifact
        }
        return canonical
    }

    /// Only the isolated application test harness may use this composition.
    /// The same anchor and coordinator protect prepare, activation, preferences, and dispatch.
    package static func verifiedOfflineFixture(
        _ fixture: OfflineFixture, root: URL, service: RaycastStoreSignedInstallationService,
        anchor: any RaycastStoreRegistryAnchor
    ) async throws -> Self {
        let coordinator = try fixture.makeCoordinator(root: root, service: service, anchor: anchor)
        try await coordinator.verifyExistingProtectedRegistry()
        var capability = Self(coordinator: coordinator)
        capability.offlineFixture = fixture
        return capability
    }
}
#endif
