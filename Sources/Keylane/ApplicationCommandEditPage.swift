import Combine
import KeylaneCore
import SwiftUI

final class ApplicationCommandEdit: ObservableObject {
    static let pageID = PageID(rawValue: "ApplicationCommandEdit")
    @Published private(set) var entry: Entry?
    @Published var alias = ""
    @Published var error = ""

    func prepare(_ entry: Entry, model: Model) {
        self.entry = entry
        alias = model.aliases[entry.id] ?? ""
        error = ""
    }

    func save(model: Model) {
        guard let entry else { return }
        model.setAlias(entry.id, value: alias)
        model.pageID = .root
    }
}

struct ApplicationCommandEditPage: View {
    @ObservedObject var editor: ApplicationCommandEdit
    let model: Model
    @StateObject private var observation: ViewObservation
    @FocusState private var aliasFocused: Bool

    init(editor: ApplicationCommandEdit, model: Model) {
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
                                     icon: { AnyView(WorkspaceItemIcon(path: entry.id)) }) { shortcut in
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
