import SwiftUI

struct DictationComposerButton: View {
    @ObservedObject var controller: DictationController
    @Binding var text: String
    @State private var fieldID = UUID()

    var body: some View {
        Button(controller.isRecordingField(fieldID) ? "完成听写" : "听写", systemImage: controller.isRecordingField(fieldID) ? "stop.circle.fill" : "mic") {
            controller.toggle(.field(fieldID) { value in
                text += (text.isEmpty || text.last?.isWhitespace == true ? "" : " ") + value
            })
        }
        .labelStyle(.iconOnly).buttonStyle(.plain).frame(width: 30, height: 30)
        .foregroundStyle(controller.isRecordingField(fieldID) ? Color.accentColor : .secondary)
        .disabled(controller.busy && !controller.isRecordingField(fieldID))
        .help("口述输入；再次点击结束")
        .onDisappear { controller.cancelField(fieldID) }
    }
}
