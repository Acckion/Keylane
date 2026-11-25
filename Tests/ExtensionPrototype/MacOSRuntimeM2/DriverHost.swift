import CryptoKit
import Darwin
import Foundation
import os
@testable import KeylaneCore

@main enum DriverHost {
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 3 else { exit(64) }
        let mode = CommandLine.arguments[1]
        let scratch = URL(fileURLWithPath: CommandLine.arguments[2])
        if mode == "reviewed-adapter" {
            do {
                for file in MacOSReviewedRaycastAPI.files {
                    let path = scratch.appendingPathComponent(file.path)
                    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try file.body.write(to: path, options: .withoutOverwriting)
                }
                exit(0)
            } catch { exit(1) }
        }
        let ownership: MacOSStoreOwnership?
        if mode == "owner-loss" {
            let path = scratch.appendingPathComponent("owner.lock")
            var info = stat()
            guard lstat(path.path, &info) == 0,
                  let lock = try? MacOSStoreOwnership(path: path, device: Int64(info.st_dev), inode: info.st_ino,
                                                      exclusive: true) else { exit(65) }
            ownership = lock
        } else {
            ownership = nil
        }
        let observed = ObservedEffects()
        let driver = MacOSRestrictedNoViewDriver(application: .main, expectedDigest: mode == "helper-digest" ? "" : FixtureSigning.digest,
                                                 signingRequirement: FixtureSigning.requirement, ownership: ownership,
                                                 deliver: { observed.record($0) })
        if mode == "batch-01-values" || mode == "batch-01-no-grants" {
            do {
                try await exerciseBatch01(driver, scratch: scratch, allow: mode == "batch-01-values")
                exit(observed.history.isEmpty ? 0 : 1)
            } catch {
                FileHandle.standardError.write(Data(String(describing: error).utf8))
                exit(1)
            }
        }
        if ["capabilities", "capability-denied", "capability-error", "capability-revoked",
            "default-async", "default-rejection", "default-pending"].contains(mode) {
            do { try await exerciseCapabilities(mode, driver: driver, observed: observed); exit(0) }
            catch { exit(1) }
        }
        if mode == "registry-disable" || mode == "registry-capabilities" {
            do {
                try await runThroughRegistry(driver: driver, scratch: scratch, withCapabilities: mode == "registry-capabilities")
                exit(mode == "registry-disable" || observed.history == ["sealed toast", "protected value"] ? 0 : 1)
            }
            catch { exit(1) }
        }
        let source: String
        switch mode {
        case "normal", "replay", "digest", "helper-digest":
            source = """
            if (["require", "process", "fetch", "Buffer", "setTimeout", "ObjC", "MacOSExtensionRunHelper"].some(name => name in globalThis)) {
                throw new Error("unexpected host API");
            }
            if (6 * 7 !== 42) throw new Error("bad evaluation");
            """
        case "exception": source = "throw new Error('synthetic')"
        case "cancel", "timeout", "parent-loss", "owner-loss": source = "while(true) {}"
        default: exit(64)
        }
        let bytes = Data(source.utf8), id = UUID()
        let receipt = StoreRuntimeBridge.Receipt(
            provenance: .init(installation: .init(id: id.uuidString, generation: 0),
                              entry: "src/main.js", projectDigest: "", runtimeDigest: ""),
            artifactDigest: mode == "digest" ? "" : MacOSExtensionBuild.hash(bytes)
        )
        let ticket = StoreGuestRunTicket(id: UUID(), profileID: UUID(), installation: .init(id: id.uuidString, generation: 1),
                                         receipt: receipt, commandID: "first-party", capabilities: [], launchContext: .init(),
                                         liveLease: { true })
        do {
            if mode == "cancel" {
                let run = Task { try await driver.run(bytes: bytes, ticket: ticket) }
                let deadline = ContinuousClock.now + .seconds(4)
                while !FileManager.default.fileExists(atPath: scratch.appendingPathComponent("cancel").path),
                      ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                run.cancel()
                do { try await run.value } catch is CancellationError { exit(0) }
                exit(1)
            }
            try await driver.run(bytes: bytes, ticket: ticket)
            if mode == "replay" {
                do { try await driver.run(bytes: bytes, ticket: ticket) }
                catch MacOSRestrictedNoViewDriver.Failure.rejected { exit(0) }
            }
            exit(mode == "normal" ? 0 : 1)
        } catch MacOSRestrictedNoViewDriver.Failure.rejected {
            exit(mode == "helper-digest" ? 0 : 1)
        } catch MacOSRestrictedNoViewDriver.Failure.invalidArtifact {
            exit(mode == "digest" ? 0 : 1)
        } catch MacOSOwnedHelperProcess.Failure.failed {
            exit(mode == "exception" || mode == "timeout" ? 0 : 1)
        } catch { exit(1) }
    }

    static func exerciseBatch01(_ driver: MacOSRestrictedNoViewDriver, scratch: URL, allow: Bool) async throws {
        let bytes = try Data(contentsOf: scratch.appendingPathComponent("Batch01.js"))
        let id = UUID()
        let receipt = StoreRuntimeBridge.Receipt(
            provenance: .init(installation: .init(id: id.uuidString, generation: 0),
                              entry: "src/main.js", projectDigest: "", runtimeDigest: ""),
            artifactDigest: MacOSExtensionBuild.hash(bytes))
        let ticket = StoreGuestRunTicket(id: UUID(), profileID: id, installation: .init(id: id.uuidString, generation: 1),
            receipt: receipt, commandID: "extension:raycast:fixture/batch-01/main",
            capabilities: allow ? feedbackFixtureCapabilities : [],
            launchContext: .init(arguments: ["grants": allow ? "on" : "off"]),
            liveLease: { true })
        try await MacOSNoViewCapabilities.$displayPreferences.withValue(.init(appearance: .light, textSize: .large)) {
            try await driver.run(bytes: bytes, ticket: ticket)
        }
    }

    @MainActor private final class ObservedEffects {
        var history: [String] = []
        func record(_ effect: MacOSNoViewCapabilities.Presentation) {
            switch effect {
            case .clearSearch(let scroll): history.append("clear:" + String(scroll))
            case .popToRoot(let clear): history.append("root:" + String(clear))
            case .closeWindow(let clear, let behavior):
                history.append("close:" + String(clear) + (behavior == .default ? "" : ":" + behavior.rawValue))
            case .copy(let text): history.append(text)
            case .toast(let presentation): history.append(presentation.title)
            }
        }
    }

    private static let feedbackFixtureCapabilities: Set<String> = MacOSNoViewCapabilities.navigation.union([
        MacOSNoViewCapabilities.preferences, MacOSNoViewCapabilities.toast, MacOSNoViewCapabilities.clipboard
    ])

    @MainActor private static func exerciseCapabilities(_ mode: String, driver: MacOSRestrictedNoViewDriver,
                                                       observed: ObservedEffects) async throws {
        let expected = ["M2 fixture", "ordinary only"] + (mode == "default-async" ? ["clear:true", "root:false"] : [])
        let denied = mode == "capability-denied"
        let throwsAfterEffects = ["capability-error", "default-rejection", "default-pending"].contains(mode)
        let revoked = mode == "capability-revoked"
        let effects = denied ? """
        if (keylane.preferences.label !== undefined || keylane.copy || keylane.toast || keylane.clearSearch || keylane.popToRoot) throw Error();
        """ : """
        if (keylane.preferences.label !== "ordinary only") throw Error();
        if (!keylane.toast(JSON.stringify({operation:"show",id:1,title:"M2 fixture",style:"SUCCESS"}))) throw Error();
        if (!keylane.copy(keylane.preferences.label)) throw Error();
        """
        let script: String
        switch mode {
        case "default-async":
            script = """
            var __keylaneCommandExports = {default: async (props) => {
                if (!Object.isFrozen(props.arguments) || !Object.isFrozen(keylane.environment)
                    || keylane.environment.appearance !== "dark" || keylane.environment.textSize !== "large") throw Error();
                await Promise.resolve();
                \(effects)
                if (!keylane.clearSearch("true") || !keylane.popToRoot("false")) throw Error();
            }};
            """
        case "default-rejection":
            script = """
            var __keylaneCommandExports = {default: async () => {
                await Promise.resolve();
                \(effects)
                throw Error();
            }};
            """
        case "default-pending":
            script = """
            var __keylaneCommandExports = {default: async () => {
                \(effects)
                await new Promise(() => {});
            }};
            """
        default:
            script = effects + (throwsAfterEffects ? "\nthrow Error();" : "")
        }
        let id = UUID(), bytes = Data(script.utf8)
        let receipt = StoreRuntimeBridge.Receipt(
            provenance: .init(installation: .init(id: id.uuidString, generation: 0), entry: "src/main.js",
                              projectDigest: "", runtimeDigest: ""), artifactDigest: MacOSExtensionBuild.hash(bytes))
        let lease = OSAllocatedUnfairLock(initialState: !revoked)
        let ticket = StoreGuestRunTicket(id: UUID(), profileID: id, installation: .init(id: id.uuidString, generation: 1),
            receipt: receipt, commandID: "first-party", capabilities: denied ? [] : feedbackFixtureCapabilities,
            launchContext: .init(ordinaryPreferences: ["label": .text("ordinary only")]),
            macOSLease: lease, liveLease: { lease.withLock { $0 } })
        do {
            let display: MacOSNoViewCapabilities.DisplayPreferences? = mode == "default-async"
                ? .init(appearance: .dark, textSize: .large) : nil
            try await MacOSNoViewCapabilities.$displayPreferences.withValue(display) {
                try await driver.run(bytes: bytes, ticket: ticket)
            }
            guard !throwsAfterEffects, !revoked, observed.history == (denied ? [] : expected) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        } catch MacOSOwnedHelperProcess.Failure.failed where throwsAfterEffects && observed.history.isEmpty {
            return
        } catch MacOSRestrictedNoViewDriver.Failure.rejected where revoked && observed.history.isEmpty {
            return
        }
    }

    // Synthetic protected head. The on-disk registry and artifact verifier are
    // the real implementations, with the isolated M1 storage tested separately.
    private final class Anchor: RaycastStoreRegistryAnchor, @unchecked Sendable {
        private let lock = NSLock()
        private var head: String?
        func verify(expectedDigest: String?) throws {
            try lock.withLock {
                guard head == expectedDigest else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
        func advance(previousDigest: String?, to nextDigest: String) throws {
            try lock.withLock {
                guard head == previousDigest else { throw CocoaError(.fileWriteUnknown) }
                head = nextDigest
            }
        }
    }

    private struct Trust: RaycastStoreArtifactTrust {
        let seal: RaycastStoreArtifactSeal
        let admission: MacOSExtensionRunAdmission
        func verify(bytes: Data, source: RaycastStoreSource, installationID: UUID) throws -> RaycastStoreTrustedDescription {
            try seal.verify(bytes: bytes, source: source, installationID: installationID)
        }
        func quarantine(installationID: UUID, before generation: UInt64) throws {
            admission.quarantine(installationID: installationID, before: generation)
        }
        func revoke(installationID: UUID, before generation: UInt64) async throws {
            await admission.revoke(installationID: installationID, before: generation)
        }
    }

    private static func runThroughRegistry(driver: MacOSRestrictedNoViewDriver, scratch: URL, withCapabilities: Bool) async throws {
        let key = P256.Signing.PrivateKey(), id = UUID(), revision = String(repeating: "a", count: 40)
        let source = try RaycastStoreSource(slug: "m2-fixture", catalog: .init(revision: revision, slugs: ["m2-fixture"]))
        let entry = "src/main.js"
        let script = withCapabilities ? """
        if (keylane.preferences.label !== "protected value") throw Error();
        if (!keylane.toast(JSON.stringify({operation:"show",id:1,title:"sealed toast",style:"SUCCESS"}))) throw Error();
        if (!keylane.copy(keylane.preferences.label)) throw Error();
        """ : "while(true) {}"
        let bytes = Data(script.utf8)
        let grants = withCapabilities ? feedbackFixtureCapabilities : []
        let original = Data(#"{"name":"m2-fixture","title":"First party","author":"fixture","platforms":["macOS"],"commands":[{"name":"main","title":"Main","mode":"no-view"}]}"#.utf8)
        var metadata = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        if withCapabilities { metadata["preferences"] = [["name":"label","title":"Label","type":"textfield","required":true]] }
        let files = [entry: bytes, "package.json": try JSONSerialization.data(withJSONObject: metadata)]
        let tree = files.map { path, data -> [String: Any] in
            let blob = Data("blob \(data.count)\0".utf8) + data
            let digest = Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
            return ["path": path, "sha": digest, "size": data.count, "mode": "100644", "type": "blob"]
        } + [["path":"src","sha":revision,"mode":"040000","type":"tree"]]
        let snapshot = try RaycastStoreSnapshot(source: source, treeSHA: revision,
            recursiveTreeJSON: JSONSerialization.data(withJSONObject: ["sha":revision,"truncated":false,"tree":tree]))
        let project = try RaycastStoreBuildProject(source: .init(snapshot: snapshot, files: files),
                                                   supportedRuntimeAPIVersions: [], tarballs: [:], target: .macOSArm64)
        let recipe = try MacOSExtensionBuild.Recipe(compilerSHA256: String(repeating: "a", count: 64),
                                                    helperSHA256: String(repeating: "b", count: 64))
        let runtime = FixtureSigning.digest
        let seal = try RaycastStoreArtifactSeal(publicKey: key.publicKey, recipe: .init(
            identifier: "m2-fixture", runtimeDigest: runtime, qualifiedAPIVersions: [], buildRecipe: recipe))
        let plan = try MacOSExtensionBuild.Plan(files: project.files.map { .init(path: $0.path, body: $0.body) }, entries: [entry])
        let request = try MacOSExtensionBuild.Request(recipe: recipe, plan: plan)
        let built = try MacOSExtensionBuild.Artifact(request: request, reply: .init(id: request.id,
            recipeDigest: recipe.digest, projectDigest: plan.digest, commands: [.init(path: entry, body: bytes)]))
        let provenance = try StoreRuntimeBridge.Provenance(installation: .init(id: id.uuidString, generation: 0),
            entry: entry, projectDigest: StoreRuntimeBridge.projectDigest(entry: entry, files: project.files.map {
                .init(path: $0.path, body: $0.body)
            }), runtimeDigest: runtime)
        let sealed = try seal.issue(source: source, installationID: id, project: project,
            built: [.init(receipt: .init(provenance: provenance, artifactDigest: MacOSExtensionBuild.hash(bytes)), artifact: bytes)],
            capabilities: grants, buildArtifact: built, sign: { try key.signature(for: $0) })
        let admission = MacOSExtensionRunAdmission()
        let registry = try RaycastStoreDiskRegistry(root: scratch.appendingPathComponent(UUID().uuidString),
            trust: Trust(seal: seal, admission: admission), anchor: Anchor())
        let staged = try await registry.prepare(bytes: sealed.bytes, expectedDigest: sealed.digest,
                                                source: source, grantedCapabilities: grants, installationID: id)
        let installed = try await registry.activate(staged)
        let command = installed.manifest.commands[0].id
        let artifact = try await registry.validate(installationID: id, generation: installed.generation,
                                                    commandID: command, capabilities: [])
        let context = RaycastStoreInstallCoordinator.RunContext(installation: installed, commandID: command,
                                                                 artifact: artifact, registry: registry)
        if withCapabilities {
            do {
                try await admission.start(context, profileID: id, seal: seal, driver: driver)
                throw CocoaError(.fileReadCorruptFile)
            } catch MacOSExtensionRunAdmission.Failure.preferencesRequired {}
            var changes = RaycastStorePreferenceChanges()
            changes.values[.init(scope: .extensionWide, name: "label")] = .set(.string("protected value"))
            try await registry.save(installationID: id, generation: installed.generation, changes: changes)
            try await admission.start(context, profileID: id, seal: seal, driver: driver)
            return
        }
        let run = Task { try await admission.start(context, profileID: id, seal: seal, driver: driver) }
        defer { run.cancel() }
        let deadline = ContinuousClock.now + .seconds(4)
        while !FileManager.default.fileExists(atPath: scratch.appendingPathComponent("disable").path) {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(10))
        }
        let disabled = try await registry.setEnabled(installationID: id, expectedGeneration: installed.generation, enabled: false)
        guard !disabled.enabled else { throw CocoaError(.fileReadCorruptFile) }
        do {
            try await run.value
            throw CocoaError(.fileReadCorruptFile)
        } catch is CancellationError {}
        _ = try await registry.setEnabled(installationID: id, expectedGeneration: disabled.generation, enabled: true)
        do {
            try await admission.start(context, profileID: id, seal: seal, driver: driver)
            throw CocoaError(.fileReadCorruptFile)
        } catch RaycastStoreDiskRegistry.Failure.stale {}
    }

}
