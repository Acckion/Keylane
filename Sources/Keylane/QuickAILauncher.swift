import AppKit
import Combine
import KeylaneCore
import SwiftUI

enum QuickAILauncher {
    static let pageID = PageID(rawValue: "quick-ai")
    static let commandID = CommandID(rawValue: "quick-ai")

    static func page(model: Model, controller: QuickAIController) -> LauncherPage {
        LauncherPage(id: pageID, placeholder: "向 AI 提问…", badge: ("Quick AI", "sparkles"),
                     contentPlacement: .underChrome, content: { AnyView(QuickAITranscript(controller: controller)) },
                     leave: controller.reset, submit: { [weak model] in
                         guard let model, !SearchField.isComposing else { return }
                         if controller.submit(model.query) { model.query = "" }
                     }, primaryTitle: { "发送" }, primaryEnabled: { [weak model] in
                         guard let model else { return false }
                         return model.aiSettings.isAvailable && !controller.running
                             && !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     }, actions: { [weak model] in
                         var actions = [LauncherAction(id: "quick-ai-copy", title: "复制回复", icon: "doc.on.doc",
                                                       enabled: controller.lastAnswer != nil) {
                             if let text = controller.lastAnswer {
                                 NSPasteboard.general.clearContents()
                                 NSPasteboard.general.setString(text, forType: .string)
                             }
                         }]
                         if controller.running {
                             actions.append(.init(id: "quick-ai-stop", title: "停止生成", icon: "stop.fill",
                                                  perform: controller.stop))
                         }
                         actions.append(.init(id: "quick-ai-reset", title: "新对话", icon: "plus") {
                             controller.reset()
                             model?.query = ""
                         })
                         return actions
                     }, updates: Publishers.Merge(
                         controller.$running.removeDuplicates().map { _ in () },
                         controller.$turns.map { $0.contains { !$0.answer.isEmpty } }.removeDuplicates().map { _ in () }
                     ).eraseToAnyPublisher())
    }
}

private struct QuickAITranscript: View {
    @ObservedObject var controller: QuickAIController
    @State private var followsBottom = true
    private let bottomID = "quick-ai-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if controller.turns.isEmpty {
                        Text("输入问题，按回车发送。").foregroundStyle(.secondary)
                    }
                    ForEach(controller.turns) { turn in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(turn.question).font(.headline).textSelection(.enabled)
                            if !turn.answer.isEmpty {
                                Text(turn.answer).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if controller.running {
                        HStack {
                            ProgressView().controlSize(.small).accessibilityLabel("正在生成")
                            Button("停止生成", action: controller.stop).buttonStyle(ContentActionButtonStyle())
                        }
                    }
                    if !controller.status.isEmpty {
                        Text(controller.status).foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id(bottomID).accessibilityHidden(true)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, VisualStyle.launcherEdgeInset)
            }
            .launcherScrollInsets()
            .launcherScrollEdgeFade()
            .onScrollPhaseChange { _, phase, context in
                if phase == .idle {
                    followsBottom = context.geometry.contentSize.height + context.geometry.contentInsets.bottom
                        - context.geometry.visibleRect.maxY < 48
                }
            }
            .onReceive(controller.$turns) { _ in
                guard followsBottom else { return }
                Task { @MainActor in proxy.scrollTo(bottomID, anchor: .bottom) }
            }
        }
    }
}
