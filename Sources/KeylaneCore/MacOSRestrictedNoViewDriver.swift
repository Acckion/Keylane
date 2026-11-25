import Foundation

/// A fresh signed helper per invocation. Construction requires a trusted
/// verifier from the native host composition, never a path from the command.
package struct MacOSRestrictedNoViewDriver: MacOSExtensionNoViewDriver {
    package enum Failure: Error { case invalidArtifact, rejected }
    private let runtime: URL
    private let hostVersion: String
    private let expectedDigest: String
    private let signingRequirement: String
    private let deliver: MacOSNoViewCapabilities.Presenter?
    private let ownership: MacOSStoreOwnership?
    private let storage: MacOSReviewedRaycastStorage?

    /// The composition root supplies the digest from the verified app profile
    /// and a signing requirement scoped to this helper's publisher and role.
    init(application: Bundle, expectedDigest: String, signingRequirement: String, ownership: MacOSStoreOwnership? = nil,
         deliver: MacOSNoViewCapabilities.Presenter? = nil, storage: MacOSReviewedRaycastStorage? = nil) {
        runtime = application.bundleURL.resolvingSymlinksInPath()
            .appendingPathComponent("Contents/Helpers/KeylaneExtensionRun.app")
        let version = application.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        hostVersion = version.flatMap { $0.isEmpty || $0.utf8.count > 64 ? nil : $0 } ?? "0.0.0"
        self.expectedDigest = expectedDigest
        self.signingRequirement = signingRequirement
        self.ownership = ownership
        self.deliver = deliver
        self.storage = storage
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
        deliver != nil || capabilities.isDisjoint(with: MacOSNoViewCapabilities.navigation.union([MacOSNoViewCapabilities.toast, MacOSNoViewCapabilities.clipboard, MacOSNoViewCapabilities.openPreferences]))
    }

    package func run(bytes: Data, ticket: StoreGuestRunTicket) async throws {
        guard !bytes.isEmpty, bytes.count <= 4 * 1024 * 1024,
              MacOSExtensionBuild.hash(bytes) == ticket.receipt.artifactDigest else { throw Failure.invalidArtifact }
        guard canDeliver(capabilities: ticket.capabilities),
              let source = String(data: bytes, encoding: .utf8) else { throw Failure.rejected }
        let canRead = ticket.capabilities.contains(MacOSNoViewCapabilities.preferences)
        let values = canRead ? try ticket.launchContext.macOSPreferences(
            includeSecrets: ticket.capabilities.contains(MacOSNoViewCapabilities.secretPreferences)) : [:]
        let fields = canRead ? try ticket.launchContext.validatedPreferenceFields() : []
        let restricted = Set(fields.compactMap { field -> String? in
            if field.type == "password", !ticket.capabilities.contains(MacOSNoViewCapabilities.secretPreferences) {
                return field.name
            }
            if ["file", "directory", "appPicker"].contains(field.type),
               !ticket.capabilities.contains(MacOSNoViewCapabilities.selectedPreferences) { return field.name }
            return nil
        })
        var environment: [String: String] = [:]
        let prefix = "extension:raycast:"
        if ticket.commandID.hasPrefix(prefix) {
            let parts = ticket.commandID.dropFirst(prefix.count).split(separator: "/")
            if parts.count == 3 {
                environment = ["ownerOrAuthorName": String(parts[0]), "extensionName": String(parts[1]),
                               "entryPointName": String(parts[2])]
            }
        }
        environment["raycastVersion"] = hostVersion
        if let display = MacOSNoViewCapabilities.displayPreferences {
            environment["appearance"] = display.appearance.rawValue
            environment["textSize"] = display.textSize.rawValue
        }
        let canUseCache = ticket.capabilities.contains(MacOSReviewedRaycastCache.capability)
        let canUseStorage = ticket.capabilities.contains(MacOSReviewedRaycastLocalStorage.capability)
        let canUseSupport = ticket.capabilities.contains(MacOSReviewedRaycastAssets.supportCapability)
        let snapshots: (cache: String?, localStorage: String?, supportFiles: [String: Data]?)
        if canUseCache || canUseStorage || canUseSupport {
            guard let storage, ticket.isCurrent() else { throw Failure.rejected }
            snapshots = try storage.read(for: ticket, cache: canUseCache, localStorage: canUseStorage, support: canUseSupport)
        } else {
            snapshots = (nil, nil, nil)
        }
        let request = try JSONEncoder().encode(MacOSNoViewCapabilities.Request(
            cacheSnapshot: snapshots.cache, localStorageSnapshot: snapshots.localStorage,
            source: source, environment: environment, arguments: ticket.launchContext.arguments,
            preferences: values.filter { !restricted.contains($0.key) },
            preferenceFields: fields.filter { !restricted.contains($0.name) },
            packagedAssets: ticket.capabilities.contains(MacOSReviewedRaycastAssets.capability) ? ticket.launchContext.packagedAssets : nil,
            supportFiles: snapshots.supportFiles,
            toast: ticket.capabilities.contains(MacOSNoViewCapabilities.toast),
            clipboard: ticket.capabilities.contains(MacOSNoViewCapabilities.clipboard),
            closeWindow: ticket.capabilities.contains(MacOSNoViewCapabilities.closeWindow),
            clearSearch: ticket.capabilities.contains(MacOSNoViewCapabilities.clearSearch),
            popToRoot: ticket.capabilities.contains(MacOSNoViewCapabilities.popToRoot),
            openPreferences: ticket.capabilities.contains(MacOSNoViewCapabilities.openPreferences),
            diagnostics: ticket.capabilities.contains(MacOSNoViewCapabilities.diagnostics)))
        guard request.count <= 8 * 1024 * 1024 else { throw Failure.rejected }
        let process = MacOSOwnedHelperProcess()
        let output = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result {
                        let helper = try verifiedHelper()
                        guard ticket.consumeForStart() else { throw Failure.rejected }
                        return try process.run(helper: helper, input: request, timeout: .seconds(5), outputLimit: 192 * 1024,
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
        if response.cache != nil {
            guard snapshots.cache != nil, let data = response.cache else { throw Failure.rejected }
            try MacOSReviewedRaycastCache.validate(data)
        }
        if let data = response.localStorage {
            guard snapshots.localStorage != nil else { throw Failure.rejected }
            try MacOSReviewedRaycastLocalStorage.validate(data)
        }
        if let data = response.supportFiles {
            guard canUseSupport else { throw Failure.rejected }
            try MacOSReviewedRaycastAssets.validateSupport(data)
        }
        let diagnostics = response.diagnostics ?? []
        guard diagnostics.count <= 16 else { throw Failure.rejected }
        for diagnostic in diagnostics { try diagnostic.validate() }
        if !presentations.isEmpty || response.cache != nil || response.localStorage != nil || response.supportFiles != nil || !diagnostics.isEmpty {
            var requiredCaps = required
            if !diagnostics.isEmpty { requiredCaps.insert(MacOSNoViewCapabilities.diagnostics) }
            if response.cache != nil { requiredCaps.insert(MacOSReviewedRaycastCache.capability) }
            if response.localStorage != nil { requiredCaps.insert(MacOSReviewedRaycastLocalStorage.capability) }
            if response.supportFiles != nil { requiredCaps.insert(MacOSReviewedRaycastAssets.supportCapability) }
            let commitCapabilities = requiredCaps
            try await MainActor.run {
                try ticket.commitMacOSEffects(commitCapabilities) {
                    if response.cache != nil || response.localStorage != nil || response.supportFiles != nil {
                        guard let storage else { throw Failure.rejected }
                        try storage.write(cache: response.cache, localStorage: response.localStorage, supportFiles: response.supportFiles, for: ticket)
                    }
                    diagnostics.forEach { $0.log() }
                    if let deliver {
                        if !diagnostics.isEmpty {
                            deliver(.diagnostics(installationID: ticket.installation.id,
                                                 generation: ticket.installation.generation, samples: diagnostics))
                        }
                        let navigationAllowed = MacOSNoViewCapabilities.allowsNavigation?() == true
                        MacOSNoViewCapabilities.$navigationCommitted.withValue(navigationAllowed) {
                            presentations.forEach(deliver)
                        }
                    }
                }
            }
        }
    }
}
