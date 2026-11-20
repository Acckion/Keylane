import AppKit
import KeylaneCore
import SwiftUI

struct AIConversationTranscript: View {
    @ObservedObject var controller: AIConversationSession
    var inLauncher = false
    var composerInset: CGFloat = VisualStyle.launcherBottomInset
    var showsEmptyHint = true
    var editTurn: ((AIConversationSession.Turn) -> Void)?
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
            .onReceive(controller.revealMessage) { id in
                followsBottom = false
                proxy.scrollTo(id, anchor: .top)
            }
            .onChange(of: controller.chatID) { _, _ in followsBottom = true }
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
        if inLauncher {
            transcript.launcherScrollInsets(bottom: false)
                .contentMargins(.bottom, composerInset, for: .scrollContent)
                .contentMargins(.bottom, composerInset, for: .scrollIndicators)
                .launcherScrollEdgeFade(bottom: composerInset + 22)
        }
        else { transcript }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: inLauncher ? 18 : 28) {
                if controller.turns.isEmpty && showsEmptyHint {
                    Text(inLauncher ? "输入问题，按回车发送。" : "输入问题开始对话。").foregroundStyle(.secondary)
                }
                ForEach(controller.turns) { turn in
                    AIConversationMessage(turn: turn, compact: inLauncher, textScale: controller.textScale,
                        interrupted: !turn.complete && (!controller.running || turn.id != controller.turns.last?.id),
                        canRevise: controller.canRevise, highlighted: searchTarget == turn.id,
                        edit: editTurn.map { edit in { edit(turn) } },
                        retry: { if controller.resubmit(turn.id) { didBranch?() } },
                        branch: { if controller.branch(after: turn.id) { didBranch?() } })
                        .equatable().id(turn.id)
                }
                if controller.running && controller.turns.last?.progress == nil {
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
}

/// Completed messages do not rebuild Markdown/progress for another turn's streaming delta.
private struct AIConversationMessage: View, Equatable {
    let turn: AIConversationTurn
    let compact: Bool
    let textScale: Double
    let interrupted: Bool
    let canRevise: Bool
    let highlighted: Bool
    let edit: (() -> Void)?
    let retry: () -> Void
    let branch: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.turn == rhs.turn && lhs.compact == rhs.compact && lhs.textScale == rhs.textScale &&
        lhs.interrupted == rhs.interrupted && lhs.canRevise == rhs.canRevise && lhs.highlighted == rhs.highlighted &&
        (lhs.edit != nil) == (rhs.edit != nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 16) {
            HStack {
                Spacer(minLength: 50)
                Text(turn.question).textSelection(.enabled).font(.system(size: 14 * textScale))
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
            if let progress = turn.progress,
               progress.active || !progress.activities.isEmpty || progress.phase == .failed || progress.phase == .cancelled {
                AIResponseProgressView(progress: progress)
            }
            if !turn.answer.isEmpty {
                ReleaseNotesBody(notes: turn.answer, textScale: textScale)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            if turn.progress == nil && interrupted {
                Text("回复未完成").font(.caption).foregroundStyle(.secondary)
            }
            if let edit {
                AIChatMessageActions(turn: turn, enabled: canRevise,
                    edit: edit,
                    retry: retry,
                    branch: branch)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted ? Color.accentColor.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))

    }
}
