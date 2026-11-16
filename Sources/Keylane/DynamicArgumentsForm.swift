import KeylaneCore
import SwiftUI

struct DynamicArgumentsForm: View {
    let title: String
    let arguments: [DynamicTemplate.Argument]
    @Binding var values: [String: String]
    let error: String?
    let back: () -> Void
    let submit: () -> Void
    @FocusState private var focused: String?

    var body: some View {
        LauncherCreationForm(back: back) {
            Text(title).font(.headline)
        } fields: {
            ForEach(arguments) { argument in
                LauncherCreationField(argument.title) {
                    LauncherCreationControl(focused: focused == argument.id) {
                        if argument.options.isEmpty {
                            TextField(argument.title, text: value(for: argument),
                                      prompt: Text(argument.defaultValue ?? "必填"))
                                .textFieldStyle(.plain)
                                .focused($focused, equals: argument.id)
                                .onSubmit {
                                    if let next = arguments.drop(while: { $0.id != argument.id }).dropFirst().first {
                                        focused = next.id
                                    } else { submit() }
                                }
                        } else {
                            Picker(argument.title, selection: value(for: argument)) {
                                Text(argument.defaultValue ?? "请选择").tag("")
                                ForEach(argument.options, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .focused($focused, equals: argument.id)
                        }
                    }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
        }
        .task { focused = arguments.first?.id }
        .onExitCommand(perform: back)
    }

    private func value(for argument: DynamicTemplate.Argument) -> Binding<String> {
        Binding(get: { values[argument.id, default: ""] }, set: { values[argument.id] = $0 })
    }
}
