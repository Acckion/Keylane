import Combine
import KeylaneCore
import SwiftUI

final class ApplicationCommandEdit: ObservableObject {
    static let pageID = PageID(rawValue: "ApplicationCommandEdit")
    @Published private(set) var entry: Entry?
    @Published var alias = ""
    @Published var error = ""
    private var isAvailable: () -> Bool = { true }

    func prepare(_ entry: Entry, model: Model, isAvailable: @escaping () -> Bool = { true }) {
        self.isAvailable = isAvailable
        self.entry = entry
        alias = model.aliases[entry.id] ?? ""
        error = ""
    }

    func save(model: Model) {
        guard let entry, validate() else { return }
        model.setAlias(entry.id, value: alias)
        model.pageID = .root
    }

    func validate() -> Bool {
        guard isAvailable() else {
            error = "此命令已不可用。"
            return false
        }
        return true
    }
}

struct ApplicationCommandEditPage: View {
    @ObservedObject var editor: ApplicationCommandEdit
    let model: Model
    let icon: (Entry) -> AnyView
    @StateObject private var observation: ViewObservation
    @FocusState private var aliasFocused: Bool

    init(editor: ApplicationCommandEdit, model: Model,
         icon: @escaping (Entry) -> AnyView = { AnyView(WorkspaceItemIcon(path: $0.id)) }) {
        self.icon = icon
        self.editor = editor
        self.model = model
        _observation = StateObject(wrappedValue: ViewObservation([ViewObservation.changes(model.$bindings)]))
    }

    var body: some View {
        LauncherCreationForm(back: { model.pageID = .root }) { EmptyView() } fields: {
            if let entry = editor.entry {
                LauncherCreationField("别名") {
                    LauncherCreationControl(focused: aliasFocused) {
                        TextField(entry.name, text: $editor.alias)
                            .textFieldStyle(.plain).focused($aliasFocused)
                            .onSubmit { editor.save(model: model) }
                    }
                }
                LauncherCreationField("快捷键", detail: "录制并确认后立即保存。") {
                    ShortcutRecorder(shortcut: model.bindings[entry.commandID.rawValue], title: entry.name,
                                     icon: { icon(entry) }, presentation: .inline) { shortcut in
                        guard editor.validate() else { return }
                        do {
                            try model.updateShortcut(entry.commandID.rawValue, value: shortcut)
                            editor.error = ""
                        } catch {
                            editor.error = error.localizedDescription
                        }
                    }
                }
                if !editor.error.isEmpty {
                    LauncherCreationField("") { Text(editor.error).foregroundStyle(.red) }
                }
            }
        }.task { aliasFocused = true }
    }
}
