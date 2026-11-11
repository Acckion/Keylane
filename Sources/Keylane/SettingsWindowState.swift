import Combine
import SwiftUI
import KeylaneCore

/// Window-level state. Launcher queries and feature progress are observed by their own views.
final class SettingsWindowState: ObservableObject {
    @Published private(set) var page: String
    @Published private(set) var commandID: CommandID?
    @Published private(set) var error: String
    @Published private(set) var colorScheme: ColorScheme?
    let catalog: SettingsWindowCatalog

    private weak var model: Model?
    private var changes: Set<AnyCancellable> = []

    init(model: Model) {
        self.model = model
        page = model.settingsPage
        commandID = model.settingsCommandID
        error = model.error
        colorScheme = model.colorScheme
        catalog = model.launcherModules?.settingsCatalog ?? SettingsWindowCatalog(pages: [])

        model.$settingsPage.removeDuplicates().dropFirst().sink { [weak self] in self?.page = $0 }.store(in: &changes)
        model.$settingsCommandID.removeDuplicates().dropFirst().sink { [weak self] in self?.commandID = $0 }.store(in: &changes)
        model.$error.removeDuplicates().dropFirst().sink { [weak self] in self?.error = $0 }.store(in: &changes)
        model.$appearance.removeDuplicates().dropFirst().sink { [weak self] in
            self?.colorScheme = $0 == "dark" ? .dark : $0 == "light" ? .light : nil
        }.store(in: &changes)
    }

    func select(_ page: String) {
        clearCommandSettings()
        model?.settingsPage = page
    }

    func command(on page: String) -> LauncherCommandDeclaration? {
        guard let commandID, let command = model?.launcherModules?.declaration(commandID),
              command.settingsPage == page else { return nil }
        return command
    }

    @ViewBuilder func commandPreferences(_ command: LauncherCommandDeclaration) -> some View {
        if let model { ExtensionCommandPreferences(model: model, commands: [command]) }
    }

    func clearCommandSettings() { model?.clearCommandSettings() }
    func clearError() { model?.error = "" }
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
