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
        public let buildRecipe: MacOSExtensionBuild.Recipe?

        public init(identifier: String, runtimeDigest: String, qualifiedAPIVersions: Set<String>, buildRecipe: MacOSExtensionBuild.Recipe? = nil) {
            self.identifier = identifier
            self.runtimeDigest = runtimeDigest
            self.qualifiedAPIVersions = qualifiedAPIVersions
            self.buildRecipe = buildRecipe
        }
    }
    public struct RunArtifact: Sendable {
        public let receipt: StoreRuntimeBridge.Receipt
        public let bytes: Data
        public let resources: [MacOSExtensionBuild.File]
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
        let build: BuildContent?
    }
    private struct BuildContent: Codable {
        let inventory: MacOSExtensionBuild.Inventory
        let resources: [MacOSExtensionBuild.File]
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
        try recipe.buildRecipe?.validate()
    }

    /// The verified resources, actual project and bridge receipts are joined here;
    /// raw guest bytes cannot self-attest source, recipe or required capabilities.
    public func issue(source: RaycastStoreSource, installationID: UUID, project: RaycastStoreBuildProject,
               built: [StoreRuntimeBridge.BuiltCommand], capabilities: Set<String>,
               buildArtifact: MacOSExtensionBuild.Artifact? = nil,
               sign: (Data) throws -> P256.Signing.ECDSASignature) throws -> RaycastStoreInstallCoordinator.BuiltArtifact {
        guard project.source == source else { throw Failure.identity }
        let files = project.files.map { StoreRuntimeBridge.File(path: $0.path, body: $0.body) }
        guard let manifestData = project.files.first(where: { $0.path == "package.json" })?.body else {
            throw Failure.malformed
        }
        let manifestFiles = project.files.map(\.path).filter { $0.hasPrefix("src/") || $0.hasPrefix("assets/") }
        let manifest = try manifest(manifestData, files: Set(manifestFiles), source: source, apiVersion: project.runtimeAPIVersion)
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
        let content: BuildContent?
        if let expectedRecipe = recipe.buildRecipe {
            guard project.target == .macOSArm64, let artifact = buildArtifact else { throw Failure.recipe }
            let plan = try MacOSExtensionBuild.Plan(files: project.files.map { .init(path: $0.path, body: $0.body) }, entries: manifest.commands.map(\.entry))
            guard artifact.inventory.projectDigest == (try plan.digest), artifact.inventory.recipeDigest == (try expectedRecipe.digest),
                  artifact.commands == built.sorted { $0.receipt.provenance.entry < $1.receipt.provenance.entry }.map({ .init(path: $0.receipt.provenance.entry, body: $0.artifact) }) else { throw Failure.integrity }
            content = .init(inventory: artifact.inventory, resources: artifact.resources)
        } else {
            guard buildArtifact == nil else { throw Failure.recipe }; content = nil
        }
        let payload = Payload(slug: source.slug, revision: source.revision, installationID: installationID,
                              recipeID: recipe.identifier, runtimeDigest: recipe.runtimeDigest,
                              apiVersion: project.runtimeAPIVersion, manifest: manifestData,
                              manifestFiles: manifestFiles.sorted(), capabilities: capabilities.sorted(),
                              commands: built.sorted { $0.receipt.provenance.entry < $1.receipt.provenance.entry }
                                .map { .init(receipt: $0.receipt, bytes: $0.artifact) }, build: content)
        _ = try checkedManifest(payload, source: source, installationID: installationID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try encoder.encode(payload)
        guard body.count <= 20 * 1024 * 1024 else { throw Failure.limit }
        let signature = try sign(body)
        guard publicKey.isValidSignature(signature, for: body) else { throw Failure.untrusted }
        let bytes = try encoder.encode(Envelope(schema: recipe.buildRecipe == nil ? 1 : 2, payload: body, signature: signature.rawRepresentation))
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
        return .init(receipt: unit.receipt, bytes: unit.bytes, resources: payload.build?.resources ?? [])
    }

    private func read(_ bytes: Data) throws -> Payload {
        guard !bytes.isEmpty, bytes.count <= Self.limit else { throw Failure.limit }
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: bytes), envelope.schema == (recipe.buildRecipe == nil ? 1 : 2),
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
        if recipe.buildRecipe != nil, let version = payload.apiVersion {
            let reviewed = try MacOSReviewedRaycastCommand.buildEntries(for: source, apiVersion: version)
            guard let capabilities = reviewed.first?.capabilities,
                  Set(payload.capabilities).isSubset(of: capabilities) else { throw Failure.recipe }
        }
        let manifest = try manifest(payload.manifest, files: Set(payload.manifestFiles), source: source, apiVersion: payload.apiVersion, sealedEntries: Set(payload.commands.map(\.receipt.provenance.entry)))
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
        if let buildRecipe = recipe.buildRecipe {
            guard let content = payload.build, content.inventory.recipeDigest == (try buildRecipe.digest) else { throw Failure.recipe }
            try MacOSExtensionBuild.verifyInventory(content.inventory,
                commands: payload.commands.map { .init(path: $0.receipt.provenance.entry, body: $0.bytes) }, resources: content.resources)
            guard manifestFilesContainResources(payload) else { throw Failure.integrity }
        } else if payload.build != nil { throw Failure.recipe }
        return manifest
    }
    private func manifest(_ data: Data, files: Set<String>, source: RaycastStoreSource,
                          apiVersion: String?, sealedEntries: Set<String>? = nil) throws -> RaycastExtensionManifest {
        if recipe.buildRecipe != nil {
            return try MacOSReviewedRaycastCommand.manifest(data: data, files: files, source: source, apiVersion: apiVersion,
                                                         sealedEntries: sealedEntries)
        }
        return try .readStoreManifest(data, files: files)
    }

    private func manifestFilesContainResources(_ payload: Payload) -> Bool {
        let resources = Set(payload.build?.resources.map(\.path) ?? [])
        return payload.manifestFiles.filter { $0.hasPrefix("assets/") }.allSatisfy(resources.contains)
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
