import CryptoKit
import Foundation

/// Durable artifact provenance. The registry can contain receipts and signatures
/// but never signing credentials. The trust anchor must be app-owned and loaded
/// separately; neither disk metadata nor guest output may name a trusted key.
public struct RaycastStoreArtifactSeal: Sendable {
    public struct Recipe: Equatable, Sendable {
        public let identifier: String
        public let runtimeDigest: String
        public let qualifiedAPIVersions: Set<String>

        public init(identifier: String, runtimeDigest: String, qualifiedAPIVersions: Set<String>) {
            self.identifier = identifier
            self.runtimeDigest = runtimeDigest
            self.qualifiedAPIVersions = qualifiedAPIVersions
        }
    }
    public struct RunArtifact: Sendable {
        public let receipt: StoreRuntimeBridge.Receipt
        public let bytes: Data
    }
    public enum Failure: Error, Equatable {
        case limit, malformed, untrusted, identity, recipe, command, integrity, generation
    }

    private struct Envelope: Codable {
        let schema: Int
        let payload: Data
        let signature: Data
    }
    private struct Payload: Codable {
        let slug: String
        let revision: String
        let installationID: UUID
        let recipeID: String
        let runtimeDigest: String
        let apiVersion: String?
        let manifest: Data
        let manifestFiles: [String]
        let capabilities: [String]
        let commands: [Unit]
    }
    private struct Unit: Codable {
        let receipt: StoreRuntimeBridge.Receipt
        let bytes: Data
    }

    private static let limit = 32 * 1024 * 1024
    private let publicKey: P256.Signing.PublicKey
    private let recipe: Recipe

    public init(publicKey: P256.Signing.PublicKey, recipe: Recipe) throws {
        guard Self.safeToken(recipe.identifier), Self.digestFormat(recipe.runtimeDigest),
              recipe.qualifiedAPIVersions.count <= 128,
              recipe.qualifiedAPIVersions.allSatisfy(Self.safeToken) else { throw Failure.recipe }
        self.publicKey = publicKey
        self.recipe = recipe
    }

    /// The verified resources, actual project and bridge receipts are joined here;
    /// raw guest bytes cannot self-attest source, recipe or required capabilities.
    @MainActor
    public func issue(source: RaycastStoreSource, installationID: UUID, project: RaycastStoreBuildProject,
               built: [StoreRuntimeBridge.BuiltCommand], capabilities: Set<String>,
               sign: (Data) throws -> P256.Signing.ECDSASignature) throws -> RaycastStoreInstallCoordinator.BuiltArtifact {
        guard project.source == source else { throw Failure.identity }
        let files = project.files.map { StoreRuntimeBridge.File(path: $0.path, body: $0.body) }
        guard let manifestData = project.files.first(where: { $0.path == "package.json" })?.body else {
            throw Failure.malformed
        }
        let manifestFiles = project.files.map(\.path).filter { $0.hasPrefix("src/") || $0.hasPrefix("assets/") }
        let manifest = try RaycastExtensionManifest.readStoreManifest(manifestData, files: Set(manifestFiles))
        guard manifest.name == source.slug, RaycastPublicCatalog.declaresMacOS(manifest.platforms) else { throw Failure.identity }
        guard (1...256).contains(built.count), built.count == manifest.commands.count,
              built.reduce(0, { $0 + min(Self.limit, $1.artifact.count) }) <= 12 * 1024 * 1024 else { throw Failure.limit }
        let entries = Set(manifest.commands.map(\.entry))
        guard Set(built.map { $0.receipt.provenance.entry }) == entries else { throw Failure.command }
        guard let entry = manifest.commands.first?.entry else { throw Failure.command }
        // Envelope encoding is independent of the command entry; hash the project
        // once, not once per command.
        let projectDigest = try StoreRuntimeBridge.projectDigest(entry: entry, files: files)
        guard built.allSatisfy({ $0.receipt.provenance.projectDigest == projectDigest }) else { throw Failure.integrity }
        let payload = Payload(slug: source.slug, revision: source.revision, installationID: installationID,
                              recipeID: recipe.identifier, runtimeDigest: recipe.runtimeDigest,
                              apiVersion: project.runtimeAPIVersion, manifest: manifestData,
                              manifestFiles: manifestFiles.sorted(), capabilities: capabilities.sorted(),
                              commands: built.sorted { $0.receipt.provenance.entry < $1.receipt.provenance.entry }
                                .map { .init(receipt: $0.receipt, bytes: $0.artifact) })
        _ = try checkedManifest(payload, source: source, installationID: installationID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try encoder.encode(payload)
        let signature = try sign(body)
        guard publicKey.isValidSignature(signature, for: body) else { throw Failure.untrusted }
        let bytes = try encoder.encode(Envelope(schema: 1, payload: body, signature: signature.rawRepresentation))
        guard bytes.count <= Self.limit else { throw Failure.limit }
        return .init(bytes: bytes, digest: Self.hex(bytes), capabilities: capabilities)
    }

    public func verify(bytes: Data, source: RaycastStoreSource, installationID: UUID) throws -> RaycastStoreTrustedDescription {
        let payload = try read(bytes)
        let manifest = try checkedManifest(payload, source: source, installationID: installationID)
        return .init(extensionID: payload.slug, manifest: manifest, requiredCapabilities: Set(payload.capabilities))
    }

    public func open(_ artifact: RaycastStoreDiskRegistry.LaunchArtifact, installation: RaycastStoreInstallation,
              commandID: String) throws -> RunArtifact {
        guard artifact.source == installation.source, Self.hex(artifact.bytes) == artifact.digest else { throw Failure.integrity }
        guard installation.enabled, installation.generation > 0 else { throw Failure.generation }
        let payload = try read(artifact.bytes)
        let manifest = try checkedManifest(payload, source: artifact.source, installationID: installation.id)
        guard let entry = manifest.commands.first(where: { $0.id == commandID })?.entry,
              let unit = payload.commands.first(where: { $0.receipt.provenance.entry == entry }) else { throw Failure.command }
        // This is extraction only; the active broker independently revalidates the
        // current generation and revocation watermark at actual admission.
        return .init(receipt: unit.receipt, bytes: unit.bytes)
    }

    private func read(_ bytes: Data) throws -> Payload {
        guard !bytes.isEmpty, bytes.count <= Self.limit else { throw Failure.limit }
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: bytes), envelope.schema == 1,
              envelope.signature.count == 64, !envelope.payload.isEmpty, envelope.payload.count <= 20 * 1024 * 1024,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: envelope.signature)
        else { throw Failure.malformed }
        guard publicKey.isValidSignature(signature, for: envelope.payload) else { throw Failure.untrusted }
        return try decoder.decode(Payload.self, from: envelope.payload)
    }

    private func checkedManifest(_ payload: Payload, source: RaycastStoreSource,
                                 installationID: UUID) throws -> RaycastExtensionManifest {
        guard payload.slug == source.slug, payload.revision == source.revision,
              payload.installationID == installationID else { throw Failure.identity }
        guard payload.recipeID == recipe.identifier, payload.runtimeDigest == recipe.runtimeDigest,
              payload.apiVersion.map(recipe.qualifiedAPIVersions.contains) ?? true else { throw Failure.recipe }
        guard payload.manifestFiles.count <= 2_048, Set(payload.manifestFiles).count == payload.manifestFiles.count,
              payload.capabilities.count <= 128, Set(payload.capabilities).count == payload.capabilities.count,
              payload.capabilities.allSatisfy(Self.safeToken), (1...256).contains(payload.commands.count) else { throw Failure.limit }
        let manifest = try RaycastExtensionManifest.readStoreManifest(payload.manifest, files: Set(payload.manifestFiles))
        guard manifest.name == source.slug, RaycastPublicCatalog.declaresMacOS(manifest.platforms) else { throw Failure.identity }
        let expected = Set(manifest.commands.map(\.entry))
        var entries = Set<String>()
        for unit in payload.commands {
            let provenance = unit.receipt.provenance
            guard expected.contains(provenance.entry), entries.insert(provenance.entry).inserted else { throw Failure.command }
            guard provenance.installation.id == installationID.uuidString, provenance.installation.generation == 0 else {
                throw Failure.generation
            }
            guard provenance.runtimeDigest == recipe.runtimeDigest, Self.digestFormat(provenance.projectDigest),
                  !unit.bytes.isEmpty, unit.bytes.count <= 4 * 1024 * 1024,
                  Self.hex(unit.bytes) == unit.receipt.artifactDigest else { throw Failure.integrity }
        }
        guard expected == entries else { throw Failure.command }
        return manifest
    }

    private static func safeToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }

    private static func digestFormat(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func hex(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
