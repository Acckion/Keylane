import SwiftUI

struct LauncherNotesPage: View {
    @ObservedObject var model: Model

    var body: some View {
        HSplitView {
            VStack { Button("新建便笺", systemImage: "plus") { model.newNote() }.padding(10); List(model.savedNotes.filter { model.query.isEmpty || $0.body.localizedCaseInsensitiveContains(model.query) }) { note in Button(note.title.isEmpty ? "未命名" : note.title) { model.noteID = note.id; model.notes = note.body }.buttonStyle(.plain) } }.frame(minWidth: 160, idealWidth: 190, maxWidth: 230)
            TextEditor(text: $model.notes).font(.system(size: 15)).scrollContentBackground(.hidden).padding(12)
        }
    }
}
