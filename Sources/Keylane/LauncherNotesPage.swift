import SwiftUI

struct LauncherNotesPage: View {
    let model: Model

    var body: some View {
        HSplitView {
            LauncherNoteList(model: model)
                .frame(minWidth: 160, idealWidth: 190, maxWidth: 230)
            LauncherNoteEditor(model: model)
        }
    }
}

private struct LauncherNoteList: View {
    let model: Model
    @StateObject private var observation: ViewObservation

    init(model: Model) {
        self.model = model
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$savedNotes),
            ViewObservation.changes(model.$query)
        ]))
    }

    var body: some View {
        let query = model.query
        let notes = query.isEmpty ? model.savedNotes : model.savedNotes.filter {
            $0.body.localizedCaseInsensitiveContains(query)
        }
        VStack {
            Button("新建便笺", systemImage: "plus") { model.newNote() }
                .buttonStyle(ContentActionButtonStyle()).padding(10)
            List(notes) { note in
                Button(note.title.isEmpty ? "未命名" : note.title) {
                    model.noteID = note.id
                    model.notes = note.body
                }.buttonStyle(.plain)
            }
        }
    }
}

private struct LauncherNoteEditor: View {
    let model: Model
    @StateObject private var observation: ViewObservation

    init(model: Model) {
        self.model = model
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$notes)
        ]))
    }

    var body: some View {
        TextEditor(text: Binding(get: { model.notes }, set: { model.notes = $0 }))
            .font(.system(size: 15)).scrollContentBackground(.hidden).padding(12)
    }
}
