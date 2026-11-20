import Foundation

/// Production integration boundary. Catalogue membership does not authorize a host
/// process or imply that an extension can run. Implementations must use the sealed
/// isolated builder/runtime and the shared installation-generation owner.
public protocol RaycastStoreBackend: Sendable {
    /// Acquire exactly the pinned source, resolve dependencies without host lifecycle
    /// scripts, build inside the isolated guest, and validate the resulting package.
    /// Return a handle only after signature/integrity/manifest validation succeeds.
    func prepare(_ source: RaycastStoreSource) async throws -> RaycastStorePreparedArtifact

    /// Consume a backend-owned immutable artifact handle. Recheck its integrity and
    /// generation at commit, then atomically persist the installation receipt. Never
    /// accept a caller path, self-reported digest or handle from another backend.
    func install(_ artifact: RaycastStorePreparedArtifact) async throws -> RaycastStoreInstallation

    /// Resolve the installed manifest, required preferences and granted capabilities,
    /// reject disabled/stale installations, then run only through the isolated helper.
    /// Must check persisted required preferences, current capabilities, runtime
    /// availability and installation generation. UI readiness is not authority:
    /// launch must repeat the checks atomically at dispatch.
    func launchReadiness(installationID: UUID, commandID: String) async throws -> RaycastStoreLaunchReadiness
    func launch(installationID: UUID, commandID: String) async throws
    func setEnabled(installationID: UUID, enabled: Bool) async throws -> RaycastStoreInstallation
    /// Read the authoritative persisted receipt after restart or an ambiguous mutation.
    func installations() async throws -> [RaycastStoreInstallation]
    func installation(for slug: String) async throws -> RaycastStoreInstallation?
    /// Revoke sessions first; confirm helper termination before removing owned files.
    func uninstall(installationID: UUID) async throws
}

/// An opaque backend receipt, not a path supplied by a catalogue entry. The production
/// verified-artifact factory belongs in KeylaneCore alongside its signature verifier;
/// UI/catalogue code cannot manufacture one from an arbitrary download.
public struct RaycastStorePreparedArtifact: Sendable {
    public let id: UUID
    public let source: RaycastStoreSource
    public let contentDigest: String
    init(id: UUID, source: RaycastStoreSource, contentDigest: String) {
        self.id = id
        self.source = source
        self.contentDigest = contentDigest
    }
}

public struct RaycastStoreInstallation: Sendable {
    public let id: UUID
    public let source: RaycastStoreSource
    public let generation: UInt64
    public let manifest: RaycastExtensionManifest
    public let enabled: Bool
    init(id: UUID, source: RaycastStoreSource, generation: UInt64,
         manifest: RaycastExtensionManifest, enabled: Bool) {
        self.id = id
        self.source = source
        self.generation = generation
        self.manifest = manifest
        self.enabled = enabled
    }
}

/// This build deliberately does not turn the preview's bundled sample copier into a
/// production installer. Keeping this explicit prevents successful browsing from
/// being reported as installation or an unknown extension from being called incompatible.
public enum RaycastStoreBackendAvailability: Equatable, Sendable {
    case unavailable(reason: String)
    case ready

    public static let current: Self = .unavailable(
        reason: "安装服务尚未接入：目录可浏览，扩展兼容性尚未验证。")
}

public enum RaycastStoreLaunchReadiness: Equatable, Sendable {
    case ready, preferencesRequired, capabilityDenied, runtimeUnavailable
}

extension RaycastStoreBackend {
    /// Fail closed until a production backend implements the required gates.
    public func launchReadiness(installationID: UUID, commandID: String) async throws -> RaycastStoreLaunchReadiness {
        .runtimeUnavailable
    }
    public func installations() async throws -> [RaycastStoreInstallation] {
        throw RaycastStoreInstaller.Failure.unavailable
    }
}
