import SwiftUI

struct DictationComposerButton: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var composer: AIConversationComposer
    @State private var fieldID = UUID()

    var body: some View {
        Button(controller.isRecordingField(fieldID) ? "完成听写" : "听写", systemImage: controller.isRecordingField(fieldID) ? "stop.circle.fill" : "mic") {
            let draft = composer.draftID
            controller.toggle(.field(fieldID) { [weak composer = composer] value in
                _ = composer?.appendDictation(value, for: draft)
            })
        }
        .labelStyle(.iconOnly).buttonStyle(.plain).frame(width: 30, height: 30)
        .foregroundStyle(controller.isRecordingField(fieldID) ? Color.accentColor : .secondary)
        .disabled(controller.busy && !controller.isRecordingField(fieldID))
        .help("口述输入；再次点击结束")
        .onChange(of: composer.draftID) { _, _ in controller.cancelField(fieldID) }
        .onDisappear { controller.cancelField(fieldID) }
    }
}
