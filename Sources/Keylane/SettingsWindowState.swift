import Combine
import SwiftUI

/// Window-level state. Launcher queries and feature progress are observed by their own views.
final class SettingsWindowState: ObservableObject {
    @Published private(set) var page: String
    @Published private(set) var navigationKeys: PageNavigationKeys
    @Published private(set) var colorScheme: ColorScheme?
    @Published private(set) var catalog: SettingsWindowCatalog

    private weak var model: Model?
    private var changes: Set<AnyCancellable> = []

    init(model: Model) {
        self.model = model
        page = model.settingsPage
        navigationKeys = model.pageNavigationKeys
        colorScheme = model.colorScheme
        let registry = model.launcherModules
        catalog = registry?.settingsCatalog ?? SettingsWindowCatalog(pages: [])

        registry?.registrationUpdates.sink { [weak self, weak registry] in
            if let registry { self?.catalog = registry.settingsCatalog }
        }.store(in: &changes)
        model.$settingsPage.removeDuplicates().dropFirst().sink { [weak self] in self?.page = $0 }.store(in: &changes)
        model.$pageNavigationKeys.removeDuplicates().dropFirst().sink { [weak self] in self?.navigationKeys = $0 }.store(in: &changes)
        model.$appearance.removeDuplicates().dropFirst().sink { [weak self] in
            self?.colorScheme = $0 == "dark" ? .dark : $0 == "light" ? .light : nil
        }.store(in: &changes)
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
