import AppKit
import SwiftUI

struct AIConversationTranscript: View {
    @ObservedObject var controller: QuickAIController
    var inLauncher = false
    var showsEmptyHint = true
    var editTurn: ((QuickAIController.Turn) -> Void)?
    var didBranch: (() -> Void)?
    var searchTarget: UUID?
    @State private var followsBottom = true
    private let bottomID = "quick-ai-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            styledScrollView
            .onScrollPhaseChange { _, phase, context in
                if phase == .idle {
                    followsBottom = context.geometry.contentSize.height + context.geometry.contentInsets.bottom
                        - context.geometry.visibleRect.maxY < 48
                }
            }
            .onChange(of: searchTarget) { _, id in
                guard let id else { return }
                followsBottom = false
                proxy.scrollTo(id, anchor: .top)
            }
            .onReceive(controller.$turns) { _ in
                guard followsBottom else { return }
                Task { @MainActor in proxy.scrollTo(bottomID, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private var styledScrollView: some View {
        if inLauncher { transcript.launcherScrollInsets().launcherScrollEdgeFade() }
        else { transcript }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: inLauncher ? 18 : 28) {
                if controller.turns.isEmpty && showsEmptyHint {
                    Text(inLauncher ? "输入问题，按回车发送。" : "输入问题开始对话。").foregroundStyle(.secondary)
                }
                ForEach(controller.turns) { turn in
                    VStack(alignment: .leading, spacing: inLauncher ? 8 : 16) {
                        HStack {
                            Spacer(minLength: 50)
                            Text(turn.question).textSelection(.enabled)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                        }
                        if let attachments = turn.attachments, !attachments.isEmpty {
                            HStack {
                                Spacer(minLength: 0)
                                ForEach(attachments) { attachment in
                                    Label(attachment.title, systemImage: attachment.symbol)
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                        .lineLimit(1).padding(7)
                                        .background(.primary.opacity(0.04), in: Capsule())
                                }
                            }
                        }
                        if !turn.answer.isEmpty {
                            ReleaseNotesBody(notes: turn.answer)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                        }
                        if !turn.complete && (!controller.running || turn.id != controller.turns.last?.id) {
                            Text("回复未完成").font(.caption).foregroundStyle(.secondary)
                        }
                        if let editTurn {
                            AIChatMessageActions(turn: turn, enabled: controller.canRevise,
                                edit: { editTurn(turn) },
                                retry: { if controller.resubmit(turn.id) { didBranch?() } },
                                branch: { if controller.branch(after: turn.id) { didBranch?() } })
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(searchTarget == turn.id ? Color.accentColor.opacity(0.06) : .clear,
                                in: RoundedRectangle(cornerRadius: 10))
                    .id(turn.id)
                }
                if controller.running {
                    HStack {
                        ProgressView().controlSize(.small).accessibilityLabel("正在生成")
                        Text("正在生成回复…").foregroundStyle(.secondary)
                        if !inLauncher {
                            Button("停止生成", action: controller.stop).buttonStyle(ContentActionButtonStyle())
                        }
                    }
                }
                if !controller.status.isEmpty {
                    Text(controller.status).foregroundStyle(.secondary)
                }
                Color.clear.frame(height: 1).id(bottomID).accessibilityHidden(true)
            }
            .padding(.horizontal, 24)
            .padding(.top, inLauncher ? 0 : 20)
            .padding(.bottom, VisualStyle.launcherEdgeInset)
        }
    }

    static func copy(_ text: String?) {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

