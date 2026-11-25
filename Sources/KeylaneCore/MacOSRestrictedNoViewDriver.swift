import Foundation

/// A fresh signed helper per invocation. Construction requires a trusted
/// verifier from the native host composition, never a path from the command.
package struct MacOSRestrictedNoViewDriver: MacOSExtensionNoViewDriver {
    package enum Failure: Error { case invalidArtifact, rejected }
    private let runtime: URL
    private let expectedDigest: String
    private let signingRequirement: String
    private let deliver: MacOSNoViewCapabilities.Presenter?
    private let ownership: MacOSStoreOwnership?

    /// The composition root supplies the digest from the verified app profile
    /// and a signing requirement scoped to this helper's publisher and role.
    init(application: Bundle, expectedDigest: String, signingRequirement: String, ownership: MacOSStoreOwnership? = nil,
         deliver: MacOSNoViewCapabilities.Presenter? = nil) {
        runtime = application.bundleURL.resolvingSymlinksInPath()
            .appendingPathComponent("Contents/Helpers/KeylaneExtensionRun.app")
        self.expectedDigest = expectedDigest
        self.signingRequirement = signingRequirement
        self.ownership = ownership
        self.deliver = deliver
    }

    func verifiedHelper() throws -> URL {
        let helper = runtime.appendingPathComponent("Contents/MacOS/keylane-extension-run")
        guard helper.standardizedFileURL == helper.resolvingSymlinksInPath() else { throw Failure.rejected }
        try MacOSBuildProfile.check(runtime, requirement: signingRequirement,
                                   entitlements: ["com.apple.security.app-sandbox": true])
        let values = try helper.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 16 * 1024 * 1024,
              MacOSExtensionBuild.hash(try Data(contentsOf: helper)) == expectedDigest else { throw Failure.rejected }
        return helper
    }

    func canDeliver(capabilities: Set<String>) -> Bool {
        deliver != nil || capabilities.isDisjoint(with: MacOSNoViewCapabilities.navigation.union([MacOSNoViewCapabilities.toast, MacOSNoViewCapabilities.clipboard]))
    }

    package func run(bytes: Data, ticket: StoreGuestRunTicket) async throws {
        guard !bytes.isEmpty, bytes.count <= 4 * 1024 * 1024,
              MacOSExtensionBuild.hash(bytes) == ticket.receipt.artifactDigest else { throw Failure.invalidArtifact }
        guard canDeliver(capabilities: ticket.capabilities),
              let source = String(data: bytes, encoding: .utf8) else { throw Failure.rejected }
        let canRead = ticket.capabilities.contains(MacOSNoViewCapabilities.preferences)
        if canRead { _ = try ticket.launchContext.preferencesReply() }
        var environment: [String: String] = [:]
        let prefix = "extension:raycast:"
        if ticket.commandID.hasPrefix(prefix) {
            let parts = ticket.commandID.dropFirst(prefix.count).split(separator: "/")
            if parts.count == 3 {
                environment = ["ownerOrAuthorName": String(parts[0]), "extensionName": String(parts[1]),
                               "entryPointName": String(parts[2])]
            }
        }
        if let display = MacOSNoViewCapabilities.displayPreferences {
            environment["appearance"] = display.appearance.rawValue
            environment["textSize"] = display.textSize.rawValue
        }
        let request = try JSONEncoder().encode(MacOSNoViewCapabilities.Request(
            source: source, environment: environment, arguments: ticket.launchContext.arguments,
            preferences: canRead ? ticket.launchContext.ordinaryPreferences : [:],
            toast: ticket.capabilities.contains(MacOSNoViewCapabilities.toast),
            clipboard: ticket.capabilities.contains(MacOSNoViewCapabilities.clipboard),
            closeWindow: ticket.capabilities.contains(MacOSNoViewCapabilities.closeWindow),
            clearSearch: ticket.capabilities.contains(MacOSNoViewCapabilities.clearSearch),
            popToRoot: ticket.capabilities.contains(MacOSNoViewCapabilities.popToRoot)))
        guard request.count <= 8 * 1024 * 1024 else { throw Failure.rejected }
        let process = MacOSOwnedHelperProcess()
        let output = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result {
                        let helper = try verifiedHelper()
                        guard ticket.consumeForStart() else { throw Failure.rejected }
                        return try process.run(helper: helper, input: request, timeout: .seconds(5), outputLimit: 65536,
                                               ownership: ownership?.descriptor)
                    })
                }
            }
        } onCancel: {
            process.cancel()
        }
        try Task.checkCancellation()
        guard ticket.isCurrent() else { throw Failure.rejected }
        let response = try JSONDecoder().decode(MacOSNoViewCapabilities.Response.self, from: output)
        let (presentations, required) = try MacOSNoViewCapabilities.validate(response, ticket: ticket)
        guard presentations.isEmpty || deliver != nil else { throw Failure.rejected }
        if let deliver, !presentations.isEmpty {
            try await MainActor.run {
                try ticket.commitMacOSEffects(required) {
                    let navigationAllowed = MacOSNoViewCapabilities.allowsNavigation?() == true
                    MacOSNoViewCapabilities.$navigationCommitted.withValue(navigationAllowed) {
                        presentations.forEach(deliver)
                    }
                }
            }
        }
    }
}
