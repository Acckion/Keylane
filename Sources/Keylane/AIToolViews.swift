import KeylaneCore
import SwiftUI

struct AIToolSettingsContent: View {
    @ObservedObject var interaction: AIInteractionPreferences
    let definitions: [AIToolDefinition]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("允许 AI 调用基础工具", isOn: $interaction.toolsEnabled)
            Text("开启后可使用所选模块的工具。剪贴板、文件正文、授权目录披露及文件创建按本次操作确认；文件访问须另行授权。工具结果发送给所选模型，关闭后停止当前请求。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(definitions, id: \.name) { tool in
                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.title).font(.subheadline)
                    Text(tool.description).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct AIToolSettingsSheet: View {
    @ObservedObject var controller: AIConversationSession
    @ObservedObject var interaction: AIInteractionPreferences
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("扩展工具").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("当前会话使用的模块").font(.subheadline)
                    ForEach(controller.toolCapabilities) { capability in
                        Toggle(capability.title, isOn: Binding(
                            get: { controller.toolSelection.permits(capability.id) },
                            set: { controller.setToolCapability(capability.id, enabled: $0) }))
                    }
                    Button("恢复使用全部模块") { controller.resetToolCapabilities() }
                    AIToolSettingsContent(interaction: interaction, definitions: controller.availableTools)
                }
            }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 440, height: 460)
    }
}

/// The same inline confirmation is used in Quick AI and AI Chat. No implicit Return approval.
struct AIToolApprovalView: View {
    @ObservedObject var broker: AIToolApprovalBroker
    var body: some View {
        if let request = broker.pending {
            VStack(alignment: .leading, spacing: 10) {
                Label("允许本次“\(request.title)”操作？", systemImage: "hand.raised").font(.headline)
                Text(request.arguments).font(.caption.monospaced()).textSelection(.enabled)
                Text("仅本次有效，60 秒未确认将自动拒绝。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("拒绝") { broker.resolve(request.id, allow: false) }
                    Button("允许本次") { broker.resolve(request.id, allow: true) }
                }.buttonStyle(.bordered)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
