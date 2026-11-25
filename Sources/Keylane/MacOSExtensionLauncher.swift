import AppKit
import Combine
import KeylaneCore

@MainActor
func withMacOSExtensionPresentation(_ delegate: Delegate?, execute: () async throws -> Void) async rethrows {
    let scope = delegate?.extensionNavigationScope()
    let display = delegate?.extensionDisplayPreferences()
    try await MacOSNoViewCapabilities.$allowsNavigation.withValue(scope) {
        try await MacOSNoViewCapabilities.$displayPreferences.withValue(display) {
            try await execute()
        }
    }
}

extension Delegate {
    @MainActor func connectInstalledMacOSExtensions(createIfMissing: Bool = false, replaceIncompatibleProfile: Bool = false) {
        let store = model.extensionStore
        let defaults = UserDefaults.standard
        let preferenceKey = store.profilePreferenceKey
        let selector = defaults.string(forKey: preferenceKey)
        guard !store.configuring, !store.backendReady, selector != nil || createIfMissing else { return }
        guard !replaceIncompatibleProfile || (createIfMissing && store.canReplaceIncompatibleProfile) else { return }
        let creating = selector == nil || replaceIncompatibleProfile
        store.configuring = true
        Task { @MainActor [weak self] in
            defer { store.configuring = false }
            guard let self else { return }
            do {
                let profileID: UUID
                if !creating, let selector {
                    guard let id = UUID(uuidString: selector) else { throw MacOSBuildProfile.Failure.identity }
                    profileID = id
                } else {
                    try MacOSBuildProfile.verifyRuntimeConfiguration(application: .main)
                    let approval = try MacOSBuildProfile.Approval(userConfirmed: createIfMissing)
                    let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                              appropriateFor: nil, create: true)
                    let profiles = support.appendingPathComponent("Keylane/ExtensionProfiles", isDirectory: true)
                    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    let root = profiles.appendingPathComponent(approval.profileID.uuidString, isDirectory: true)
                    _ = try await MacOSBuildProfile.enroll(approval, root: root, application: .main)
                    profileID = approval.profileID
                }
                let backend = try await MacOSStoreBuildInstallationService.open(id: profileID, application: .main,
                    deliver: { [weak self] presentation in self?.presentMacOSExtensionEffect(presentation) },
                    requiresRuntime: true)
                let installations = try await backend.installations()
                if creating {
                    if let selector {
                        let archiveKey = preferenceKey + ".previous"
                        var archived = defaults.stringArray(forKey: archiveKey) ?? []
                        if !archived.contains(selector) { archived.append(selector) }
                        defaults.set(archived, forKey: archiveKey)
                    }
                    defaults.set(profileID.uuidString, forKey: preferenceKey)
                }
                store.attach(backend)
                for installation in installations {
                    await self.updateMacOSExtensionModule(installation, replacing: nil)
                }
                await store.restoreInstalled()
            } catch MacOSBuildProfile.Failure.buildRecipeChanged {
                store.canReplaceIncompatibleProfile = true
                store.configurationError = "此预览版的扩展运行工具已更新。请重新配置运行环境。"
            } catch RaycastStoreDiskRegistry.Failure.busy {
                store.configurationError = "另一实例正在使用此扩展配置。请退出另一实例后重试。"
            } catch {
                store.configurationError = "无法打开扩展运行配置。请确认已登录 macOS 并解锁钥匙串后重试。"
            }
        }
    }

    @MainActor func updateMacOSExtensionModule(_ installation: RaycastStoreInstallation?, replacing previousID: UUID?) async {
        let store = model.extensionStore
        guard let backend = store.backend, let registry = model.launcherModules else { return }
        do {
            if let previousID, previousID != installation?.id {
                if store.launcherModules[previousID]?.installed == true {
                    try registry.uninstall(.init(rawValue: "store:" + previousID.uuidString))
                }
                store.launcherModules.removeValue(forKey: previousID)
            }
            guard let installation, store.launcherModules[installation.id]?.generation != installation.generation else { return }
            let module: LauncherModule?
            if installation.enabled {
                module = await InstalledMacOSExtension(installation: installation, backend: backend, delegate: self).module()
            } else {
                module = nil
            }
            if let module {
                try registry.install(module)
            } else if store.launcherModules[installation.id]?.installed == true {
                try registry.uninstall(.init(rawValue: "store:" + installation.id.uuidString))
            }
            store.launcherModules[installation.id] = (installation.generation, module != nil)
        } catch {
            showLauncherFeedback("无法更新启动器中的扩展命令。", style: .failure)
        }
    }

    @MainActor private func presentMacOSExtensionEffect(_ presentation: MacOSNoViewCapabilities.Presentation) {
        switch presentation {
        case .toast(let toast):
            let style: ToastStyle
            switch toast.style {
            case .success: style = .success
            case .failure: style = .failure
            case .animated: style = .neutral
            }
            let message = [toast.title, toast.message ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            showLauncherFeedback(message, style: style)
        case .closeWindow(let clearSearch, let behavior):
            guard MacOSNoViewCapabilities.navigationCommitted else { return }
            hideLauncher(suspendReturn: behavior == .suspended)
            if behavior == .immediate || (behavior == .default && clearSearch) {
                model.pageID = .root
            }
            if clearSearch, model.pageID == .root { clearExtensionSearch(forceScrollToTop: true) }
        case .clearSearch(let forceScroll):
            guard MacOSNoViewCapabilities.navigationCommitted else { return }
            clearExtensionSearch(forceScrollToTop: forceScroll)
        case .popToRoot(let clear):
            guard MacOSNoViewCapabilities.navigationCommitted else { return }
            model.pageID = .root
            if clear { clearExtensionSearch(forceScrollToTop: true) }
        case .copy(let text):
            if !ExtensionClipboardContent(text: text).write(to: .general) {
                showLauncherFeedback("无法复制到剪贴板。", style: .failure)
            }
        }
    }
}

@MainActor private final class InstalledMacOSExtension {
    let installation: RaycastStoreInstallation
    let backend: RaycastStoreInstallCoordinator
    weak var delegate: Delegate?
    private var running: Task<Void, Never>?

    init(installation: RaycastStoreInstallation, backend: RaycastStoreInstallCoordinator, delegate: Delegate) {
        self.installation = installation
        self.backend = backend
        self.delegate = delegate
    }

    func module() async -> LauncherModule? {
        var commands: [LauncherModule.Command] = []
        for command in installation.manifest.commands where command.mode == .noView && !command.disabledByDefault {
            guard let readiness = try? await backend.launchReadiness(installationID: installation.id, commandID: command.id),
                  readiness == .ready || readiness == .preferencesRequired else { continue }
            let reviewed = MacOSReviewedRaycastCommand.entry(forCommandID: command.id)
            let inputs = reviewed?.argumentNames ?? []
            commands.append(.init(declaration: .init(id: .init(rawValue: command.id), title: command.title,
                detail: command.description ?? installation.manifest.title, symbol: "puzzlepiece.extension",
                keywords: command.keywords), execute: { _ in self.run(command.id) },
                arguments: inputs.isEmpty ? nil : .init(
                    count: (reviewed?.argumentIsOptional == true ? 0 : inputs.count)...inputs.count,
                    execute: { _, arguments in
                        self.run(command.id, arguments: Dictionary(uniqueKeysWithValues: zip(inputs, arguments)))
                    })))
        }
        guard !commands.isEmpty else { return nil }
        return LauncherModule(id: .init(rawValue: "store:" + installation.id.uuidString),
            origin: .installedExtension, title: installation.manifest.title, commands: commands,
            services: [.init(start: {}, stop: { self.running?.cancel() })],
            registration: .init(isPresent: { true }, updates: Empty<Void, Never>().eraseToAnyPublisher(),
                                generation: { self.installation.generation }))
    }

    private func run(_ commandID: String, arguments: [String: String] = [:]) {
        guard running == nil else { return }
        running = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.running = nil }
            do {
                try await withMacOSExtensionPresentation(self.delegate) {
                    try await self.backend.launch(self.installation, commandID: commandID, arguments: arguments)
                }
                if MacOSReviewedRaycastCommand.entry(forCommandID: commandID) == nil {
                    self.delegate?.showLauncherFeedback("扩展命令已完成。", style: .success)
                }
            }
            catch is CancellationError {}
            catch { self.delegate?.showLauncherFeedback("扩展命令未能完成。", style: .failure) }
        }
    }
}
