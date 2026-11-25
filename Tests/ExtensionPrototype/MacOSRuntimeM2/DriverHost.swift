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
                for file in MacOSReviewedRaycastAPI.files + MacOSReviewedRaycastAssets.files {
                    let path = scratch.appendingPathComponent(file.path)
                    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try file.body.write(to: path, options: .withoutOverwriting)
                }
                exit(0)
            } catch { exit(1) }
        }
        if mode == "reviewed-view-adapter" {
            do {
                for file in MacOSReviewedRaycastViewAdapter.files {
                    let path = scratch.appendingPathComponent(file.path)
                    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try file.body.write(to: path, options: .withoutOverwriting)
                }
                for name in ["Batch03NativeView", "Batch03LegacyRender", "Batch03ViewEffects"] {
                    try MacOSReviewedRaycastViewAdapter.wrapper(command: name + ".tsx")
                        .write(to: scratch.appendingPathComponent(name + "Entry.mjs"), options: .withoutOverwriting)
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data(String(describing: error).utf8))
                exit(1)
            }
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
                                                 deliver: { observed.record($0) },
                                                 storage: mode.hasPrefix("batch-02-") ? .init(root: scratch) : nil)
        if mode.hasPrefix("batch-03-hud-") {
            do {
                let allowed = mode == "batch-03-hud-allowed"
                try await exerciseHUD(driver, scratch: scratch, navigation: allowed)
                exit(observed.history == (allowed ? ["close:true:suspended", "Scoped HUD"] : []) ? 0 : 1)
            } catch {
                FileHandle.standardError.write(Data(String(describing: error).utf8))
                exit(1)
            }
        }
        if mode.hasPrefix("view-production-") {
            do {
                try await runThroughRegistry(driver: driver, scratch: scratch, withCapabilities: false, viewMode: mode)
                let expected = mode == "view-production-effects"
                    ? ["clear:false", "close:false:suspended", "View HUD", "root:true", "close:false"] : []
                if observed.history != expected {
                    FileHandle.standardError.write(Data(String(describing: observed.history).utf8))
                    exit(1)
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data(String(describing: error).utf8))
                exit(1)
            }
        }
        if mode == "view-session-react" || mode == "view-session-react-group-denied" {
            do {
                try exerciseReactView(scratch: scratch, helper: driver.verifiedHelper(), chooseGroup: mode.hasSuffix("group-denied"))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data(String(describing: error).utf8))
                exit(1)
            }
        }
        if mode.hasPrefix("view-session-feedback-") {
            do {
                try exerciseViewFeedback(mode, helper: driver.verifiedHelper())
                exit(0)
            } catch {
                FileHandle.standardError.write(Data(String(describing: error).utf8))
                exit(1)
            }
        }
        if mode.hasPrefix("view-session-") {
            do {
                try exerciseViewSession(mode, helper: driver.verifiedHelper())
                exit(0)
            } catch {
                FileHandle.standardError.write(Data(String(describing: error).utf8))
                exit(1)
            }
        }
        if mode == "batch-01-values" || mode == "batch-01-no-grants" {
            do {
                try await exerciseBatch01(driver, scratch: scratch, allow: mode == "batch-01-values")
                exit(observed.history.isEmpty ? 0 : 1)
            } catch {
                FileHandle.standardError.write(Data(String(describing: error).utf8))
                exit(1)
            }
        }
        if mode.hasPrefix("batch-02-files-") {
            do {
                let phase = String(mode.dropFirst("batch-02-files-".count))
                let allowed = phase != "denied"
                let bytes = try Data(contentsOf: scratch.appendingPathComponent("Batch02Assets.js"))
                let id = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
                let lease = OSAllocatedUnfairLock(initialState: true)
                let receipt = StoreRuntimeBridge.Receipt(
                    provenance: .init(installation: .init(id: id.uuidString, generation: 0),
                                      entry: "src/main.js", projectDigest: "", runtimeDigest: ""),
                    artifactDigest: MacOSExtensionBuild.hash(bytes))
                var context = StoreGuestLaunchContext(arguments: ["mode": phase])
                context.packagedAssets = try MacOSReviewedRaycastAssets.contents([
                    .init(path: "assets/sub/hello.txt", body: Data("你好".utf8)),
                    .init(path: "assets/bytes.bin", body: Data([0, 128, 255])),
                    .init(path: "package.json", body: Data("excluded".utf8)),
                ])
                let ticket = StoreGuestRunTicket(id: UUID(), profileID: id,
                    installation: .init(id: id.uuidString, generation: 1), receipt: receipt,
                    commandID: "extension:raycast:fixture/batch-02-assets/main",
                    capabilities: allowed ? [MacOSReviewedRaycastAssets.capability, MacOSReviewedRaycastAssets.supportCapability, MacOSReviewedRaycastCache.capability] : [],
                    launchContext: context, macOSLease: lease, liveLease: { lease.withLock { $0 } })
                try await driver.run(bytes: bytes, ticket: ticket)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data(String(describing: error).utf8))
                exit(1)
            }
        }
        if mode.hasPrefix("batch-02-") {
            do {
                try await exerciseBatch02(driver, scratch: scratch, mode: String(mode.dropFirst("batch-02-".count)))
                let expected = mode == "batch-02-write" ? ["extension preferences", "extension:raycast:fixture/batch-02/main"] : []
                let diagnosticsMatch = mode == "batch-02-write"
                    ? observed.diagnostics.count == 2 && observed.diagnostics[0].exceptionCategory == .object
                        && observed.diagnostics[1].residentBytes != nil
                    : observed.diagnostics.isEmpty
                exit(observed.history == expected && diagnosticsMatch ? 0 : 1)
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

    static func exerciseHUD(_ driver: MacOSRestrictedNoViewDriver, scratch: URL, navigation: Bool) async throws {
        let bytes = try Data(contentsOf: scratch.appendingPathComponent("Batch03HUD.js"))
        let id = UUID(), lease = OSAllocatedUnfairLock(initialState: true)
        let receipt = StoreRuntimeBridge.Receipt(
            provenance: .init(installation: .init(id: id.uuidString, generation: 0),
                              entry: "src/main.js", projectDigest: "", runtimeDigest: ""),
            artifactDigest: MacOSExtensionBuild.hash(bytes))
        let grants: Set<String> = navigation ? [MacOSNoViewCapabilities.toast, MacOSNoViewCapabilities.closeWindow] : [MacOSNoViewCapabilities.toast]
        let ticket = StoreGuestRunTicket(id: UUID(), profileID: id, installation: .init(id: id.uuidString, generation: 1),
            receipt: receipt, commandID: "extension:raycast:fixture/batch-03/main", capabilities: grants,
            launchContext: .init(arguments: ["navigation": navigation ? "on" : "off"]),
            macOSLease: lease, liveLease: { lease.withLock { $0 } })
        try await driver.run(bytes: bytes, ticket: ticket)
    }

    static func exerciseReactView(scratch: URL, helper: URL, chooseGroup: Bool) throws {
        let script = try String(contentsOf: scratch.appendingPathComponent("Batch03React.js"), encoding: .utf8)
        let mailbox = MacOSReviewedViewSession.Mailbox()
        var snapshots: [String] = []
        do {
            try MacOSReviewedViewSession.run(helper: helper, source: script, process: .init(), timeout: .seconds(4),
                mailbox: mailbox, isCurrent: { true }) { detail, revision in
                    snapshots.append(detail.markdown)
                    let actionID = chooseGroup ? "counter" : "increment"
                    mailbox.submit(revision < 2 ? .action(.action(actionID)) : .finish, revision: revision)
                }
        } catch MacOSReviewedViewSession.Failure.invalidEvent where chooseGroup && snapshots == ["count:0"] {
            return
        }
        guard !chooseGroup, snapshots == ["count:0", "count:1", "count:2"] else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    static func exerciseViewFeedback(_ mode: String, helper: URL) throws {
        let source = """
        const copy = { id: "copy", title: "Copy", style: "regular" };
        const retry = { id: "retry", title: "Retry", style: "regular" };
        var __keylaneCommandExports = {
            default: () => ({
                markdown: "prompt", actions: [copy],
                confirmation: { title: "Continue?", acceptTitle: "Continue" }
            }),
            onEvent: async event => {
                await Promise.resolve();
                if (event.kind === "confirm") {
                    return { markdown: "accepted", actions: [copy], toast: { title: "Completed", primary: retry } };
                }
                if (event.kind === "dismiss") return { markdown: "dismissed", actions: [] };
                if (event.kind === "toastAction" && event.actionID === "retry") {
                    return { markdown: "retried", actions: [] };
                }
                throw new Error("Unexpected event");
            }
        };
        """
        let mailbox = MacOSReviewedViewSession.Mailbox()
        var observed = [String]()
        do {
            try MacOSReviewedViewSession.run(helper: helper, source: source, process: .init(), timeout: .seconds(4),
                mailbox: mailbox, isCurrent: { true }) { detail, revision in
                    observed.append(detail.markdown)
                    let selection: MacOSReviewedViewSession.Mailbox.Selection
                    switch (mode, revision) {
                    case ("view-session-feedback-dismiss", 0): selection = .action(.dismiss)
                    case ("view-session-feedback-blocked", 0): selection = .action(.action("copy"))
                    case (_, 0): selection = .action(.confirm)
                    case ("view-session-feedback-blocked-toast", 1): selection = .action(.toastAction("copy"))
                    case ("view-session-feedback-confirm-toast", 1): selection = .action(.toastAction("retry"))
                    default: selection = .finish
                    }
                    mailbox.submit(selection, revision: revision)
                }
        } catch MacOSReviewedViewSession.Failure.invalidEvent
            where mode == "view-session-feedback-blocked" || mode == "view-session-feedback-blocked-toast" {
            let expected = mode == "view-session-feedback-blocked" ? ["prompt"] : ["prompt", "accepted"]
            guard observed == expected else { throw CocoaError(.fileReadCorruptFile) }
            return
        }
        let expected = mode == "view-session-feedback-dismiss" ? ["prompt", "dismissed"] : ["prompt", "accepted", "retried"]
        guard observed == expected else { throw CocoaError(.fileReadCorruptFile) }
    }

    static func exerciseViewSession(_ mode: String, helper: URL) throws {
        let source = """
        let count = 0;
        const root = () => ({ markdown: `count:${count}`, actions: [
            { id: "advance", title: "Advance", style: "regular" }
        ] });
        var __keylaneCommandExports = {
            default: root,
            onEvent: async event => {
                await Promise.resolve();
                if (event.kind === "action" && event.actionID === "advance") {
                    count++;
                    return { markdown: `detail:${count}`, actions: [] };
                }
                if (event.kind === "back") return root();
                throw new Error("Unexpected event");
            }
        };
        """
        let process = MacOSOwnedHelperProcess()
        let mailbox = MacOSReviewedViewSession.Mailbox()
        var observed = [String]()
        var current = true
        do {
            try MacOSReviewedViewSession.run(helper: helper, source: source, process: process, timeout: .seconds(4),
                                               mailbox: mailbox, isCurrent: { current }) { detail, revision in
                observed.append(detail.markdown)
                let selection: MacOSReviewedViewSession.Mailbox.Selection
                switch (mode, observed.count) {
                case ("view-session-updates", 1): selection = .action(.action("advance"))
                case ("view-session-updates", 2): selection = .action(.back)
                case ("view-session-stale-action", 1), ("view-session-stale-action", 2): selection = .action(.action("advance"))
                case ("view-session-revoked", 1):
                    current = false
                    selection = .action(.action("advance"))
                default: selection = .finish
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(75)) {
                    _ = mailbox.submit(.finish, revision: revision - 1)
                    mailbox.submit(selection, revision: revision)
                }
            }
        } catch MacOSReviewedViewSession.Failure.invalidEvent where mode == "view-session-stale-action" {
            guard observed == ["count:0", "detail:1"] else { throw CocoaError(.fileReadCorruptFile) }
            return
        } catch MacOSReviewedViewSession.Failure.retired where mode == "view-session-revoked" {
            guard observed == ["count:0"] else { throw CocoaError(.fileReadCorruptFile) }
            return
        }
        guard mode == "view-session-updates", observed == ["count:0", "detail:1", "count:1"] else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    static func exerciseBatch02(_ driver: MacOSRestrictedNoViewDriver, scratch: URL, mode: String) async throws {
        let bytes = try Data(contentsOf: scratch.appendingPathComponent("Batch02.js"))
        // All calls use the same temporary installation and a fresh one-shot ticket.
        let id = "00000000-0000-4000-8000-000000000002"
        let receipt = StoreRuntimeBridge.Receipt(
            provenance: .init(installation: .init(id: id, generation: 0),
                              entry: "src/main.js", projectDigest: "", runtimeDigest: ""),
            artifactDigest: MacOSExtensionBuild.hash(bytes))
        let fields = try JSONDecoder().decode([RaycastExtensionManifest.Field].self,
            from: Data(#"[{"name":"label","type":"textfield","title":"Label","required":true,"default":"fallback"},{"name":"secret","type":"password"},{"name":"file","type":"file"},{"name":"directory","type":"directory"},{"name":"application","type":"appPicker"}]"#.utf8))
        guard let app = RaycastApplicationValue(url: URL(fileURLWithPath: "/fixture/Test.app"),
                                                name: "Fixture", bundleId: "org.keylane.tests.synthetic") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var context = StoreGuestLaunchContext(arguments: ["mode": mode],
            ordinaryPreferences: ["label": .text("chosen"), "file": .text("/fixture/document.txt"),
                                  "directory": .text("/fixture"), "application": .application(app)], preferenceFields: fields)
        context.passwordValues = ["secret": "synthetic-fixture-value"]
        var grants: Set<String> = []
        if mode != "denied" {
            grants = [MacOSNoViewCapabilities.preferences, MacOSNoViewCapabilities.openPreferences,
                      MacOSNoViewCapabilities.diagnostics, MacOSReviewedRaycastCache.capability,
                      MacOSReviewedRaycastLocalStorage.capability]
            if mode != "ordinary-only" {
                grants.formUnion([MacOSNoViewCapabilities.secretPreferences, MacOSNoViewCapabilities.selectedPreferences])
            }
        }
        let lease = OSAllocatedUnfairLock(initialState: true)
        let ticket = StoreGuestRunTicket(id: UUID(), profileID: UUID(), installation: .init(id: id, generation: 1),
            receipt: receipt, commandID: "extension:raycast:fixture/batch-02/main", capabilities: grants,
            launchContext: context, macOSLease: lease, liveLease: { lease.withLock { $0 } })
        do {
            try await driver.run(bytes: bytes, ticket: ticket)
            if mode == "failed" { throw CocoaError(.fileReadCorruptFile) }
        } catch MacOSOwnedHelperProcess.Failure.failed where mode == "failed" {
            return
        }
    }

    @MainActor private final class ObservedEffects {
        var history: [String] = []
        var diagnostics: [MacOSNoViewCapabilities.Diagnostic] = []
        func record(_ effect: MacOSNoViewCapabilities.Presentation) {
            switch effect {
            case .diagnostics(_, _, let samples): diagnostics.append(contentsOf: samples)
            case .openPreferences(_, _, let command): history.append(command ?? "extension preferences")
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

    private static func runThroughRegistry(driver: MacOSRestrictedNoViewDriver, scratch: URL, withCapabilities: Bool, viewMode: String? = nil) async throws {
        let key = P256.Signing.PrivateKey(), id = UUID(), revision = String(repeating: "a", count: 40)
        let source = try RaycastStoreSource(slug: "m2-fixture", catalog: .init(revision: revision, slugs: ["m2-fixture"]))
        let entry = "src/main.js"
        let script = withCapabilities ? """
        if (keylane.preferences.label !== "protected value") throw Error();
        if (!keylane.toast(JSON.stringify({operation:"show",id:1,title:"sealed toast",style:"SUCCESS"}))) throw Error();
        if (!keylane.copy(keylane.preferences.label)) throw Error();
        """ : "while(true) {}"
        let bytes: Data
        if let viewMode {
            let file = if viewMode.hasSuffix("legacy") { "Batch03LegacyRender.js" }
                else if viewMode.contains("effects") { "Batch03ViewEffects.js" }
                else { "Batch03NativeView.js" }
            bytes = try Data(contentsOf: scratch.appendingPathComponent(file))
        } else {
            bytes = Data(script.utf8)
        }
        let grants = if viewMode == "view-production-no-grant" { Set<String>() }
            else if viewMode == "view-production-effects" {
                MacOSNoViewCapabilities.navigation.union([MacOSReviewedViewSession.capability, MacOSNoViewCapabilities.toast])
            } else if viewMode != nil { Set([MacOSReviewedViewSession.capability]) }
            else { withCapabilities ? feedbackFixtureCapabilities : [] }
        let original = Data(#"{"name":"m2-fixture","title":"First party","author":"fixture","platforms":["macOS"],"commands":[{"name":"main","title":"Main","mode":"no-view"}]}"#.utf8)
        var metadata = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        if viewMode != nil {
            metadata["commands"] = [["name": "main", "title": "Main", "mode": "view"]]
        }
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
        if let viewMode {
            var snapshots: [MacOSReviewedViewSession.Detail] = []
            let mailbox = MacOSReviewedViewSession.Mailbox()
            if viewMode == "view-production-no-presentation" {
                do {
                    try await admission.start(context, profileID: id, seal: seal, driver: driver)
                    throw CocoaError(.fileReadCorruptFile)
                } catch MacOSExtensionRunAdmission.Failure.unsupportedCommand {
                    return
                }
            }
            let presentation = MacOSReviewedViewSession.Presentation(mailbox: mailbox) { snapshot, revision in
                snapshots.append(snapshot)
                let items = snapshot.actions
                let selection: MacOSReviewedViewSession.Mailbox.Selection
                if viewMode.hasSuffix("legacy") || viewMode.hasSuffix("no-grant") || viewMode.contains("effects") {
                    selection = .finish
                } else if viewMode.hasSuffix("revoked") {
                    Task { _ = try await registry.setEnabled(installationID: id, expectedGeneration: installed.generation, enabled: false) }
                    return
                } else {
                    switch revision {
                    case 0:
                        if items.count == 3, let submenu = items.last {
                            selection = .action(.search(submenu.id, query: "sample"))
                        } else { selection = .finish }
                    case 1: selection = items.last?.children?.first.map { .action(.action($0.id)) } ?? .finish
                    case 2: selection = items.dropFirst().first.map { .action(.action($0.id)) } ?? .finish
                    case 3: selection = .action(.back)
                    case 4: selection = items.first.map { .action(.action($0.id)) } ?? .finish
                    case 5: selection = .action(viewMode.hasSuffix("decline") ? .dismiss : .confirm)
                    case 6: selection = snapshot.toast?.secondary.map { .action(.toastAction($0.id)) } ?? .finish
                    case 7: selection = snapshot.toast?.primary.map { .action(.toastAction($0.id)) } ?? .finish
                    default: selection = .finish
                    }
                }
                mailbox.submit(selection, revision: revision)
            }
            do {
                try await MacOSReviewedViewSession.$presentation.withValue(presentation) {
                    try await admission.start(context, profileID: id, seal: seal, driver: driver)
                }
            } catch MacOSExtensionRunAdmission.Failure.unsupportedCommand
                where viewMode.hasSuffix("no-grant") && snapshots.isEmpty { return }
            catch is CancellationError where viewMode.hasSuffix("revoked") && snapshots.count == 1 { return }
            if viewMode.hasSuffix("legacy"), snapshots.map(\.markdown) == ["legacy render"] { return }
            if viewMode.contains("effects"), snapshots.map(\.markdown) == ["view effects"] {
                guard snapshots[0].effects?.count ?? 0 == (viewMode == "view-production-effects" ? 5 : 0) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return
            }
            let choice = viewMode.hasSuffix("decline") ? "declined" : "accepted"
            guard snapshots.map(\.markdown) == ["ready", "ready", "selected:sample", "child", "returned", "returned", choice, "retried", "undone"],
                  snapshots[0].actions.first?.shortcut?.key == "g", snapshots[0].actions.last?.searchable == true,
                  snapshots[1].actions.last?.children?.first?.title == "sample", snapshots[3].depth == 1,
                  snapshots[4].depth == 0, snapshots[5].toast?.style == .animated,
                  snapshots[5].confirmation?.cancelTitle == "Decline", snapshots[5].confirmation?.destructive == true,
                  snapshots[6].confirmation == nil, snapshots[6].toast?.title == "Choice saved",
                  snapshots[6].toast?.style == .success, snapshots[7].toast?.style == .failure,
                  snapshots[7].toast?.message == "Retry failed", snapshots[8].toast == nil
            else {
                FileHandle.standardError.write(Data(String(describing: snapshots).utf8))
                throw CocoaError(.fileReadCorruptFile)
            }
            return
        }
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
