import CryptoKit
import Foundation
import KeylaneCore
import SwiftUI

@MainActor final class FixtureModel: ObservableObject {
    @Published var status = "未配置签名测试包。"
    @Published var busy = false
    @Published var receipt: RaycastStoreInstallation?
    @Published var configured = false
    private let authority = FixtureAuthority()
    private var installer: RaycastStoreInstaller?
    private var source: RaycastStoreSource?
    private var reopenBackend: (() throws -> RaycastStoreInstallCoordinator)?

    enum Preflight: String, Encodable {
        case arguments, scratchLocation, signedHelper, runtimeDigest, seal, project, protectedScope, registry, service, ready
    }
    private(set) var lastPreflight: Preflight = .arguments
    var ready: Bool { installer != nil && lastPreflight == .ready }

    func configure(arguments: [String]) async {
        guard arguments.count == 5, arguments[1] == "--signed-scratch-helper" else { return }
        do {
            lastPreflight = .scratchLocation
            let scratch = URL(fileURLWithPath: arguments[2], isDirectory: true).resolvingSymlinksInPath()
            // URL normalization may rewrite /private/tmp as /tmp. Compare
            // canonical component arrays for both sides, never a literal prefix.
            let base = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath().pathComponents
            let components = scratch.pathComponents
            let candidatePrefix = "keylane-store-context-signed."
            let leaf = Array(components.dropFirst(base.count))
            guard components.starts(with: base), leaf.count == 3,
                  leaf[0].hasPrefix(candidatePrefix), leaf[0].count > candidatePrefix.count,
                  leaf[1] == "unpacked", leaf[2] == "KeylaneStorePackagingProbe.app",
                  let outer = Bundle(url: scratch) else { throw FixtureFailure.invalid }
            let team = arguments[3], expectedDigest = arguments[4], authority = self.authority
            let driver = StoreGuestProcessDriver(teamIdentifier: team, isCurrent: { authority.isCurrent($0) },
                grants: { authority.isCurrent($0) ? [.clipboardCopy, .hud, .preferencesRead] : [] },
                launchContext: { identity, receipt in
                    guard authority.isCurrent(identity), receipt.provenance.entry == "src/entry.ts",
                          let context = authority.launchContext else { throw FixtureFailure.invalid }
                    return context
                }) { identity, capability, body in
                    guard authority.isCurrent(identity) else { throw FixtureFailure.invalid }
                    switch capability {
                    case .clipboardCopy:
                        guard authority.runEvents.isEmpty, body == "synthetic:00112233445566778899AABBCCDDEEFF" else {
                            throw FixtureFailure.invalid
                        }
                        authority.copyCount += 1
                    case .hud:
                        guard authority.runEvents == [.clipboardCopy], body == "Paste was denied" else {
                            throw FixtureFailure.invalid
                        }
                        authority.hudCount += 1
                    default:
                        throw FixtureFailure.invalid
                    }
                    // These are in-memory observations only, not Mac pasteboard
                    // writes or UI/navigation actions.
                    authority.runEvents.append(capability)
                    return ""
                }
            lastPreflight = .signedHelper
            let engine = try StoreSignedGuestEngine.installed(in: outer, expectedTeam: team,
                                                              recipeIdentifier: FixtureProject.recipe, driver: driver)
            lastPreflight = .runtimeDigest
            guard try engine.verifiedRuntimeDigest() == expectedDigest else { throw FixtureFailure.invalid }
            lastPreflight = .seal
            let recipe = RaycastStoreArtifactSeal.Recipe(identifier: FixtureProject.recipe, runtimeDigest: expectedDigest,
                                                        qualifiedAPIVersions: [])
            let signer = P256.Signing.PrivateKey() // Process-local fixture only.
            let seal = try RaycastStoreArtifactSeal(publicKey: signer.publicKey, recipe: recipe)
            let anchor = try RaycastStoreProtectedReceiptState(storage: FixtureAnchorStorage(), registryID: UUID(),
                                                                publicKey: signer.publicKey, recipe: recipe)
            let statePath = FileManager.default.temporaryDirectory
                .appendingPathComponent("keylane-store-lifecycle-fixture-" + UUID().uuidString, isDirectory: true)
            lastPreflight = .protectedScope
            try anchor.initializeNewRegistry(observedRegistryDigest: nil)
            let service = LifecycleService(seal: seal, signer: signer, engine: engine, authority: authority)
            lastPreflight = .project
            let (source, project) = try FixtureProject.load()
            let backend = {
                try RaycastStoreInstallCoordinator(root: statePath, service: service, anchor: anchor) { requested, qualified in
                    guard requested == source, qualified.isEmpty else { throw FixtureFailure.invalid }
                    return project
                }
            }
            self.source = source
            lastPreflight = .registry
            let fresh = RaycastStoreInstaller(backend: try backend())
            lastPreflight = .service
            guard try await fresh.refreshInstalled().isEmpty else { throw FixtureFailure.invalid }
            installer = fresh
            reopenBackend = backend
            lastPreflight = .ready
            status = "已核对签名与运行时摘要；尚未运行虚拟机。"
        } catch {
            status = "签名测试包、资源摘要或临时隔离状态无效；未启动。"
        }
    }

    enum Action { case install, configure, run, toggle, reopen, uninstall }
    @discardableResult
    func act(_ action: Action) async -> Bool {
        guard let installer, let source, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            switch action {
            case .install:
                receipt = try await installer.prepareAndInstall(source)
                status = "已安装自写样例；配置前不能运行。"
            case .configure:
                guard receipt != nil else { throw FixtureFailure.invalid }
                authority.configuration = .init(values: [.init(scope: .extensionWide, name: "action"): .string("copy")])
                configured = true
                status = "已写入本次样例配置（仅内存）。"
            case .run:
                guard let command = receipt?.manifest.commands.first else { throw FixtureFailure.invalid }
                let previous = (authority.copyCount, authority.hudCount)
                try await installer.launch(slug: source.slug, commandID: command.id)
                guard (authority.copyCount, authority.hudCount) == (previous.0 + 1, previous.1 + 1) else { throw FixtureFailure.invalid }
                status = "已记录样例复制和提示；未改动系统剪贴板。"
            case .toggle:
                guard let receipt else { throw FixtureFailure.invalid }
                try await installer.setEnabled(slug: source.slug, enabled: !receipt.enabled)
                self.receipt = await installer.installedList().first
                status = self.receipt?.enabled == true ? "已重新启用。" : "已停用。"
            case .reopen:
                guard let reopenBackend else { throw FixtureFailure.invalid }
                let reopened = RaycastStoreInstaller(backend: try reopenBackend())
                receipt = try await reopened.refreshInstalled().first
                self.installer = reopened
                status = "已重开注册表；本进程保留临时签名和配置。"
            case .uninstall:
                try await installer.uninstall(slug: source.slug)
                receipt = nil; authority.configuration = .init(); configured = false
                status = "已卸载自写样例。"
            }
            return true
        } catch {
            status = (error as? RaycastStoreInstaller.Failure)?.errorDescription ?? "操作未通过验证。"
            return false
        }
    }

    struct Observation {
        let builtArtifactDigest: String?
        let buildCount: Int
        let confirmedRunCount: Int
        let copyCount: Int
        let hudCount: Int
    }

    var observe: Observation {
        .init(builtArtifactDigest: authority.builtArtifactDigest, buildCount: authority.buildCount,
              confirmedRunCount: authority.confirmedRunCount, copyCount: authority.copyCount, hudCount: authority.hudCount)
    }

    func confirmsLaunchDenial(_ expected: RaycastStoreInstaller.Failure) async -> Bool {
        guard let installer, let source, let command = receipt?.manifest.commands.first else { return false }
        let before = observe
        do { try await installer.launch(slug: source.slug, commandID: command.id); return false }
        catch let failure as RaycastStoreInstaller.Failure {
            return failure == expected && before.confirmedRunCount == observe.confirmedRunCount && before.copyCount == observe.copyCount && before.hudCount == observe.hudCount
        } catch { return false }
    }
}

@MainActor struct StoreLifecycleFixtureLauncher: App {
    @StateObject private var model = FixtureModel()

    var body: some Scene {
        Window("Keylane 签名扩展流程 · 仅测试", id: "store-fixture") {
            VStack(alignment: .leading, spacing: 12) {
                Text("自写隔离样例，没有真实偏好、扩展或账户数据。")
                Text(model.status).accessibilityIdentifier("fixture-status")
                HStack {
                    action("安装", .install, allowed: model.receipt == nil)
                    action("配置", .configure, allowed: model.receipt != nil && !model.configured)
                    action("运行", .run, allowed: model.receipt?.enabled == true)
                    action(model.receipt?.enabled == true ? "停用" : "启用", .toggle, allowed: model.receipt != nil)
                }
                HStack {
                    action("重开注册表", .reopen, allowed: true)
                    action("卸载", .uninstall, allowed: model.receipt != nil)
                }
            }
            .padding(24)
            .task { if !model.ready { await model.configure(arguments: CommandLine.arguments) } }
        }
    }

    private func action(_ title: String, _ action: FixtureModel.Action, allowed: Bool) -> some View {
        Button(title) { Task { await model.act(action) } }
            .disabled(!model.ready || !allowed || model.busy)
    }
}
