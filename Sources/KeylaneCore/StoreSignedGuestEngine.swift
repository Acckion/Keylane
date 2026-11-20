import CryptoKit
import Foundation
import Security

/// App-callable signed resource adapter; does not select a driver or expose a
/// Store backend. Only app-owned code may supply a guest driver and trust
/// policy. The package, extension manifest, and command never select either.
@MainActor
public struct StoreSignedGuestEngine: StoreRuntimeBridge.IsolatedEngine {
    public struct Trust: Equatable, Sendable {
        public let signingIdentifier: String
        public let teamIdentifier: String
        public let recipeIdentifier: String

        public init(signingIdentifier: String, teamIdentifier: String, recipeIdentifier: String) {
            self.signingIdentifier = signingIdentifier
            self.teamIdentifier = teamIdentifier
            self.recipeIdentifier = recipeIdentifier
        }
    }

    public struct Resources: Sendable {
        public let kernelURL: URL
        public let ramdiskURL: URL
        public let digest: String
        public let recipeIdentifier: String
        var codeDirectoryHash: Data? = nil
    }

    /// The driver must boot these exact resources in a fresh VM for each call.
    /// No host evaluation or command runner fallback is permitted. The run
    /// driver is responsible for live broker authorization and revocation.
    @MainActor
    public protocol Driver {
        func buildInFreshGuest(resources: Resources, envelope: Data, entry: String) async throws -> Data
        func runInFreshGuest(
            resources: Resources, artifact: Data, receipt: StoreRuntimeBridge.Receipt,
            installation: StoreRuntimeBridge.Installation
        ) async throws
        var supportsTicketedLaunch: Bool { get }
        func runInFreshGuest(resources: Resources, artifact: Data, ticket: StoreGuestRunTicket) async throws
    }

    private let loadResources: @MainActor () throws -> Resources
    private let driver: any Driver

    /// Resolve from an app-controlled, stable bundle location, not a temporary
    /// or package-writable location. The boot loader opens URL-backed files.
    public init(bundle: Bundle, trust: Trust, driver: any Driver) {
        self.init(driver: driver) { try Self.load(bundle: bundle, trust: trust) }
    }

    /// Discover only the signed nested helper in the application's installed
    /// bundle. The expected team/recipe must come from app-owned configuration.
    /// Missing distributions remain unavailable and cannot fall back to a
    /// developer cache, external image, or host-process runner.
    public static func installed(
        in application: Bundle, expectedTeam: String, recipeIdentifier: String, driver: any Driver
    ) throws -> Self {
        let location = application.bundleURL.appendingPathComponent("Contents/Helpers/KeylaneStoreGuest.app")
        let expected = application.bundleURL.resolvingSymlinksInPath()
            .appendingPathComponent("Contents/Helpers/KeylaneStoreGuest.app")
        guard location.resolvingSymlinksInPath().path == expected.path,
              let helper = Bundle(url: location),
              helper.executableURL?.lastPathComponent == "KeylaneStoreGuest",
              helper.object(forInfoDictionaryKey: "KeylaneStoreGuestRecipe") as? String == recipeIdentifier else {
            throw StoreRuntimeBridge.Rejection.runtimeIdentity
        }
        let engine = Self(bundle: helper, trust: .init(
            signingIdentifier: "org.keylane.launcher.store-guest", teamIdentifier: expectedTeam,
            recipeIdentifier: recipeIdentifier
        ), driver: driver)
        _ = try engine.verifiedRuntimeDigest()
        return engine
    }

    // For focused contract tests only; the public entry always verifies the seal.
    init(driver: any Driver, loadResources: @escaping @MainActor () throws -> Resources) {
        self.loadResources = loadResources
        self.driver = driver
    }

    public func verifiedRuntimeDigest() throws -> String {
        try loadResources().digest
    }

    /// Verify this helper's own bundle before any isolated runner uses its
    /// fixed resource URLs. The caller still owns signing-team/recipe pinning.
    public static func verifiedResources(in bundle: Bundle, trust: Trust) throws -> Resources {
        try load(bundle: bundle, trust: trust)
    }

    public func build(projectEnvelope: Data, entry: String, runtimeDigest: String) async throws -> Data {
        guard !projectEnvelope.isEmpty, projectEnvelope.count <= 46 * 1024 * 1024 else {
            throw StoreRuntimeBridge.Rejection.projectLimit
        }
        let resources = try requireResources(runtimeDigest)
        try Task.checkCancellation()
        return try await driver.buildInFreshGuest(resources: resources, envelope: projectEnvelope, entry: entry)
    }

    public func run(
        artifact: Data, receipt: StoreRuntimeBridge.Receipt, installation: StoreRuntimeBridge.Installation
    ) async throws {
        guard receipt.provenance.installation.id == installation.id,
              installation.generation > 0,
              receipt.provenance.installation.generation <= installation.generation else {
            throw StoreRuntimeBridge.Rejection.staleInstallation
        }
        guard !artifact.isEmpty, artifact.count <= 4 * 1024 * 1024,
              Self.hex(SHA256.hash(data: artifact)) == receipt.artifactDigest else {
            throw StoreRuntimeBridge.Rejection.artifactIdentity
        }
        let resources = try requireResources(receipt.provenance.runtimeDigest)
        try Task.checkCancellation()
        try await driver.runInFreshGuest(resources: resources, artifact: artifact,
                                         receipt: receipt, installation: installation)
    }

    public var supportsTicketedLaunch: Bool { driver.supportsTicketedLaunch }

    public func run(artifact: Data, ticket: StoreGuestRunTicket) async throws {
        guard supportsTicketedLaunch, ticket.isCurrent(), ticket.installation.generation > 0,
              ticket.receipt.provenance.installation.id == ticket.installation.id,
              ticket.receipt.provenance.installation.generation == 0 else {
            throw StoreRuntimeBridge.Rejection.staleInstallation
        }
        guard !artifact.isEmpty, artifact.count <= 4 * 1024 * 1024,
              Self.hex(SHA256.hash(data: artifact)) == ticket.receipt.artifactDigest else {
            throw StoreRuntimeBridge.Rejection.artifactIdentity
        }
        let resources = try requireResources(ticket.receipt.provenance.runtimeDigest)
        try Task.checkCancellation()
        guard ticket.isCurrent() else { throw StoreRuntimeBridge.Rejection.staleInstallation }
        try await driver.runInFreshGuest(resources: resources, artifact: artifact, ticket: ticket)
    }

    private func requireResources(_ expected: String) throws -> Resources {
        let resources = try loadResources()
        guard expected == resources.digest else { throw StoreRuntimeBridge.Rejection.runtimeIdentity }
        return resources
    }

    private static func load(bundle: Bundle, trust: Trust) throws -> Resources {
        // Values become string literals in the Security.framework requirement.
        // Keep the grammar small rather than escaping untrusted requirement text.
        let valid = { (value: String) in
            !value.isEmpty && value.utf8.count <= 128 &&
            value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || [45, 46, 95].contains($0) }
        }
        guard valid(trust.signingIdentifier), valid(trust.teamIdentifier), valid(trust.recipeIdentifier),
              let directory = bundle.resourceURL,
              bundle.bundleURL.pathExtension == "app" else { throw StoreRuntimeBridge.Rejection.runtimeIdentity }
        let requirementText = "anchor apple generic and identifier \"\(trust.signingIdentifier)\" and certificate leaf[subject.OU] = \"\(trust.teamIdentifier)\""
        var requirement: SecRequirement?
        var code: SecStaticCode?
        // Pin the slice that our native Child is expected to execute. A
        // different host/slice must fail closed rather than accept another hash.
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        throw StoreRuntimeBridge.Rejection.runtimeIdentity
        #endif
        let attributes = [kSecCodeAttributeArchitecture as String: architecture] as CFDictionary
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckNestedCode | kSecCSStrictValidate | kSecCSCheckAllArchitectures))
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPathAndAttributes(bundle.bundleURL as CFURL, [], attributes, &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess,
              let codeDirectoryHash = Self.codeDirectoryHash(code) else {
            throw StoreRuntimeBridge.Rejection.runtimeIdentity
        }
        let kernel = directory.appendingPathComponent("Image")
        let ramdisk = directory.appendingPathComponent("ingress.cpio")
        let kernelHash = try shaFile(kernel, in: directory, maximum: 128 * 1024 * 1024)
        let ramdiskHash = try shaFile(ramdisk, in: directory, maximum: 512 * 1024 * 1024)
        // Do not return a digest from an intervening, unsealed resource read.
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess,
              Self.codeDirectoryHash(code) == codeDirectoryHash else {
            throw StoreRuntimeBridge.Rejection.runtimeIdentity
        }
        let binding = ["keylane-store-signed-guest-v1", trust.signingIdentifier, trust.teamIdentifier,
                       trust.recipeIdentifier, kernelHash, ramdiskHash].joined(separator: "\n")
        return Resources(kernelURL: kernel, ramdiskURL: ramdisk, digest: hex(SHA256.hash(data: Data(binding.utf8))),
                         recipeIdentifier: trust.recipeIdentifier, codeDirectoryHash: codeDirectoryHash)
    }

    nonisolated static func codeDirectoryHash(_ code: SecStaticCode) -> Data? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
              let hash = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              hash.count == 20 else { return nil }
        return hash
    }

    private static func shaFile(_ url: URL, in directory: URL, maximum: Int) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink == false,
              url.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath(),
              let size = values.fileSize, size > 0, size <= maximum else {
            throw StoreRuntimeBridge.Rejection.runtimeIdentity
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        var total = 0
        while let data = try file.read(upToCount: 64 * 1024), !data.isEmpty {
            guard data.count <= size - total else { throw StoreRuntimeBridge.Rejection.runtimeIdentity }
            total += data.count
            hash.update(data: data)
        }
        guard total == size else { throw StoreRuntimeBridge.Rejection.runtimeIdentity }
        return hex(hash.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}


extension StoreSignedGuestEngine.Driver {
    public var supportsTicketedLaunch: Bool { false }
    public func runInFreshGuest(resources: StoreSignedGuestEngine.Resources, artifact: Data, ticket: StoreGuestRunTicket) async throws {
        // Until the native driver acknowledges ticket consumption and stop,
        // never fall back to its installation-only entry point.
        throw StoreRuntimeBridge.Rejection.staleInstallation
    }
}
