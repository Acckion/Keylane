import CryptoKit
import Foundation

/// The store may browse the whole catalog, but runtime execution still requires
/// an enabled installation and a current artifact from the sealed builder.
@MainActor
public struct StoreRuntimeBridge {
    public struct Installation: Codable, Equatable, Sendable {
        public let id: String
        public let generation: UInt64

        public init(id: String, generation: UInt64) {
            self.id = id
            self.generation = generation
        }
    }

    public struct File: Sendable {
        public let path: String
        public let body: Data

        public init(path: String, body: Data) {
            self.path = path
            self.body = body
        }
    }

    public struct Provenance: Codable, Equatable, Sendable {
        public let installation: Installation
        public let entry: String
        public let projectDigest: String
        public let runtimeDigest: String
    }

    /// Keep this metadata in the trusted installation registry, independently
    /// from the untrusted artifact bytes. Never derive it from a run request.
    public struct Receipt: Codable, Equatable, Sendable {
        public let provenance: Provenance
        public let artifactDigest: String

        public init(provenance: Provenance, artifactDigest: String) {
            self.provenance = provenance
            self.artifactDigest = artifactDigest
        }
    }

    public struct BuiltCommand: Sendable {
        public let receipt: Receipt
        public let artifact: Data
    }

    public enum Rejection: Error, Equatable {
        case invalidProject, projectLimit, runtimeIdentity, staleInstallation, artifactIdentity
    }

    /// Implementations are app-owned adapters to the sealed guest, NOT services
    /// selected by the manifest. Verify signed runtime resources on every launch,
    /// including the run phase; the verified digest also covers the fixed build
    /// recipe. Keep run mode in a fresh guest and bind its broker session to
    /// the live installation generation for ongoing revocation. The bridge's
    /// two snapshot checks do not replace broker revocation while a guest runs.
    /// There is intentionally no host-process fallback.
    @MainActor
    public protocol IsolatedEngine {
        func verifiedRuntimeDigest() throws -> String
        func build(projectEnvelope: Data, entry: String, runtimeDigest: String) async throws -> Data
        func run(artifact: Data, receipt: Receipt, installation: Installation) async throws
        var supportsTicketedLaunch: Bool { get }
        func run(artifact: Data, ticket: StoreGuestRunTicket) async throws
    }

    private struct Envelope: Encodable {
        let version = 1
        let files: [Record]
    }

    private struct Record: Encodable {
        let path: String
        let body: Data
        let sha256: String
    }

    public enum Operation: Sendable {
        case stagingBuild, enabledRun
    }

    private let engine: any IsolatedEngine
    private let currentInstallation: @MainActor (Installation, Operation) async throws -> Bool

    public init(
        engine: any IsolatedEngine,
        currentInstallation: @escaping @MainActor (Installation, Operation) async throws -> Bool
    ) {
        self.engine = engine
        self.currentInstallation = currentInstallation
    }

    public func prepare(installation: Installation, entry: String, files: [File]) async throws -> BuiltCommand {
        try await requireCurrent(installation, operation: .stagingBuild)
        let envelope = try Self.projectEnvelope(entry: entry, files: files)
        let runtimeDigest = try engine.verifiedRuntimeDigest()
        guard Self.isDigest(runtimeDigest) else { throw Rejection.runtimeIdentity }
        let provenance = Provenance(
            installation: installation, entry: entry, projectDigest: Self.digest(envelope),
            runtimeDigest: runtimeDigest
        )
        try Task.checkCancellation()
        let artifact = try await engine.build(projectEnvelope: envelope, entry: entry, runtimeDigest: runtimeDigest)
        try Task.checkCancellation()
        try await requireCurrent(installation, operation: .stagingBuild)
        try Task.checkCancellation()
        guard try engine.verifiedRuntimeDigest() == runtimeDigest else { throw Rejection.runtimeIdentity }
        guard Self.validArtifactSize(artifact) else { throw Rejection.artifactIdentity }
        return BuiltCommand(receipt: Receipt(provenance: provenance, artifactDigest: Self.digest(artifact)), artifact: artifact)
    }

    public func run(artifact: Data, ticket: StoreGuestRunTicket) async throws {
        let provenance = ticket.receipt.provenance
        guard engine.supportsTicketedLaunch, ticket.isCurrent(), ticket.installation.generation > 0,
              provenance.installation.id == ticket.installation.id,
              provenance.installation.generation == 0 else { throw Rejection.staleInstallation }
        try await requireCurrent(ticket.installation, operation: .enabledRun)
        guard Self.isDigest(provenance.runtimeDigest),
              try engine.verifiedRuntimeDigest() == provenance.runtimeDigest else { throw Rejection.runtimeIdentity }
        guard Self.isDigest(provenance.projectDigest), Self.validPath(provenance.entry),
              Self.validArtifactSize(artifact), Self.digest(artifact) == ticket.receipt.artifactDigest else {
            throw Rejection.artifactIdentity
        }
        try Task.checkCancellation()
        guard ticket.isCurrent() else { throw Rejection.staleInstallation }
        try await engine.run(artifact: artifact, ticket: ticket)
        try Task.checkCancellation()
        guard ticket.isCurrent() else { throw Rejection.staleInstallation }
        try await requireCurrent(ticket.installation, operation: .enabledRun)
    }

    public func run(artifact: Data, expectedReceipt: Receipt, installation: Installation) async throws {
        let provenance = expectedReceipt.provenance
        guard provenance.installation.id == installation.id,
              provenance.installation.generation <= installation.generation else { throw Rejection.staleInstallation }
        try await requireCurrent(installation, operation: .enabledRun)
        guard Self.isDigest(provenance.runtimeDigest),
              try engine.verifiedRuntimeDigest() == provenance.runtimeDigest else { throw Rejection.runtimeIdentity }
        guard Self.isDigest(provenance.projectDigest), Self.validPath(provenance.entry),
              Self.validArtifactSize(artifact), Self.digest(artifact) == expectedReceipt.artifactDigest else {
            throw Rejection.artifactIdentity
        }
        try Task.checkCancellation()
        try await engine.run(artifact: artifact, receipt: expectedReceipt, installation: installation)
        try Task.checkCancellation()
        try await requireCurrent(installation, operation: .enabledRun)
    }

    private func requireCurrent(_ installation: Installation, operation: Operation) async throws {
        guard !installation.id.isEmpty, operation == .stagingBuild || installation.generation > 0,
              try await currentInstallation(installation, operation) else { throw Rejection.staleInstallation }
    }

    static func projectDigest(entry: String, files: [File]) throws -> String {
        try digest(projectEnvelope(entry: entry, files: files))
    }

    private static func projectEnvelope(entry: String, files: [File]) throws -> Data {
        guard !files.isEmpty, files.count <= 4096 else { throw Rejection.projectLimit }
        guard validPath(entry) else { throw Rejection.invalidProject }
        var aliases = Set<String>()
        var total = 0
        for file in files {
            guard validPath(file.path), aliases.insert(file.path.lowercased()).inserted else {
                throw Rejection.invalidProject
            }
            guard file.body.count <= 32 * 1024 * 1024 - total else { throw Rejection.projectLimit }
            total += file.body.count
        }
        guard files.contains(where: { $0.path == entry }) else { throw Rejection.invalidProject }
        for path in aliases {
            var prefix = ""
            for component in path.split(separator: "/").dropLast() {
                prefix += prefix.isEmpty ? String(component) : "/" + component
                guard !aliases.contains(prefix) else { throw Rejection.invalidProject }
            }
        }
        let records = files.sorted { $0.path < $1.path }.map {
            Record(path: $0.path, body: $0.body, sha256: digest($0.body))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(Envelope(files: records))
        guard encoded.count <= 46 * 1024 * 1024 else { throw Rejection.projectLimit }
        return encoded
    }

    private static func validPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 1024,
              path.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || [95, 64, 46, 43, 47, 45].contains($0) }) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix("-")
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func validArtifactSize(_ artifact: Data) -> Bool {
        !artifact.isEmpty && artifact.count <= 4 * 1024 * 1024
    }
}


extension StoreRuntimeBridge.IsolatedEngine {
    public var supportsTicketedLaunch: Bool { false }
    public func run(artifact: Data, ticket: StoreGuestRunTicket) async throws {
        // A legacy installation-only engine cannot consume this request.
        throw StoreRuntimeBridge.Rejection.staleInstallation
    }
}
