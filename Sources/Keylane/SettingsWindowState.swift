import AppKit
import Combine
import KeylaneCore
import SwiftUI

/// Window-level state. Launcher queries and feature progress are observed by their own views.
final class SettingsWindowState: ObservableObject {
    @Published private(set) var page: String
    @Published private(set) var navigationKeys: PageNavigationKeys
    @Published private(set) var colorScheme: ColorScheme?
    @Published private(set) var catalog: SettingsWindowCatalog

    private weak var model: Model?
    private var permissionRecovery: [String: AnyCancellable] = [:]
    private var changes: Set<AnyCancellable> = []

    init(model: Model) {
        self.model = model
        page = model.settingsPage
        navigationKeys = model.pageNavigationKeys
        colorScheme = model.colorScheme
        let registry = model.launcherModules
        catalog = registry?.settingsCatalog ?? SettingsWindowCatalog(pages: [])

        registry?.availabilityChanges.sink { [weak self] in self?.objectWillChange.send() }.store(in: &changes)
        registry?.registrationUpdates.sink { [weak self, weak registry] in
            if let registry { self?.catalog = registry.settingsCatalog }
        }.store(in: &changes)
        model.$settingsPage.removeDuplicates().dropFirst().sink { [weak self] in self?.page = $0 }.store(in: &changes)
        model.$pageNavigationKeys.removeDuplicates().dropFirst().sink { [weak self] in self?.navigationKeys = $0 }.store(in: &changes)
        model.$appearance.removeDuplicates().dropFirst().sink { [weak self] in
            self?.colorScheme = $0 == "dark" ? .dark : $0 == "light" ? .light : nil
        }.store(in: &changes)
    }

    func extensionEnabled(for page: String) -> Binding<Bool>? {
        guard let registry = model?.launcherModules, let id = registry.module(forSettingsPage: page) else { return nil }
        return Binding(get: { registry.isModuleEnabled(id) }, set: { [weak model] in model?.setModuleEnabled(id, $0) })
    }

    func titlebar(for page: String) -> SettingsTitlebarContribution? {
        let contribution = catalog.page(page)?.titlebar
        guard let model, let registry = model.launcherModules,
              let module = registry.module(forSettingsPage: page) else { return contribution }

        let moduleEnabled = registry.availabilityChanges.map { [weak registry] _ in
            registry?.isModuleEnabled(module) == true
        }.prepend(registry.isModuleEnabled(module))
        let featureEnabled = contribution?.updates ?? Just(true).eraseToAnyPublisher()
        return SettingsTitlebarContribution(
            title: contribution?.title ?? "启用扩展",
            help: contribution?.help ?? "关闭后停止此扩展的后台活动，保留数据与快捷键。",
            enabled: Binding(get: { [weak registry] in
                registry?.isModuleEnabled(module) == true && contribution?.enabled.wrappedValue != false
            }, set: { [weak self, weak model] enabled in
                self?.permissionRecovery[page] = nil
                guard enabled else {
                    model?.setModuleEnabled(module, false)
                    return
                }
                if let contribution, let request = contribution.requestEnable {
                    request { [weak self] granted in
                        if granted { self?.model?.setModuleEnabled(module, true) }
                        else { self?.observePermissionRecovery(for: page, module: module, contribution: contribution) }
                    }
                } else {
                    contribution?.enabled.wrappedValue = true
                    model?.setModuleEnabled(module, true)
                }
            }),
            updates: moduleEnabled.combineLatest(featureEnabled).map { $0 && $1 }.removeDuplicates().eraseToAnyPublisher(),
            searchItem: contribution?.searchItem,
            permissionStatus: contribution?.permissionStatus,
            openPrivacySettings: contribution?.openPrivacySettings.map { open in
                { [weak self] in
                    if let contribution {
                        self?.observePermissionRecovery(for: page, module: module, contribution: contribution)
                    }
                    open()
                }
            }
        )
    }

    private func observePermissionRecovery(for page: String, module: ModuleID, contribution: SettingsTitlebarContribution) {
        permissionRecovery[page] = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                contribution.recheckPermission?()
                guard contribution.enabled.wrappedValue else { return }
                self?.permissionRecovery[page] = nil
                self?.model?.setModuleEnabled(module, true)
            }
    }

    func select(_ page: String) { model?.settingsPage = page }
}


/// Observe only the values a view renders, even if they share a controller.
final class ViewObservation: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private var changes: AnyCancellable?

    init(_ inputs: [AnyPublisher<Void, Never>]) {
        changes = Publishers.MergeMany(inputs).sink { [weak self] in self?.objectWillChange.send() }
    }

    static func changes<P: Publisher>(_ publisher: P) -> AnyPublisher<Void, Never>
    where P.Output: Equatable, P.Failure == Never {
        publisher.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
    }
}
