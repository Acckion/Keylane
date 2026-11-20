import KeylaneCore
import SwiftUI

struct AIToolSettingsContent: View {
    @ObservedObject var interaction: AIInteractionPreferences
    let definitions: [AIToolDefinition]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("允许 AI 调用基础工具", isOn: $interaction.toolsEnabled)
            Text("开启后可使用已登记的工具。文件访问与创建须在 AI 设置中另行启用并添加目录，文件披露、创建与打开应用每次确认。工具结果发送给所选模型，关闭后停止当前请求。")
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
    @ObservedObject var interaction: AIInteractionPreferences
    let definitions: [AIToolDefinition]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("扩展工具").font(.headline)
            ScrollView { AIToolSettingsContent(interaction: interaction, definitions: definitions) }
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
