import SwiftUI
import KeylaneCore

/// Tool settings share the composer control; remaining capability placeholders are explicit.
struct AIChatCapabilitySection: View {
    @ObservedObject var interaction: AIInteractionPreferences
    let definitions: [AIToolDefinition]
    @State private var information: AIChatCapabilityInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AIToolSettingsContent(interaction: interaction, definitions: definitions)
            section("技能", symbol: "square.stack.3d.up", feature: .skills,
                    detail: "技能发现与执行尚未接入，不会加载本地脚本。")
            VStack(alignment: .leading, spacing: 6) {
                Text("工具权限").font(.subheadline)
                Text("只读工具沿用已有授权；打开应用逐次确认。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $information) { AIChatCapabilityInfoView(feature: $0) }
    }

    private func section(_ title: String, symbol: String, feature: AIChatCapabilityInfo, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.subheadline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Button("查看接入状态…") { information = feature }.buttonStyle(.bordered).controlSize(.small)
        }
    }
}

enum AIChatCapabilityInfo: String, Identifiable {
    case skills, voice
    var id: Self { self }
    var title: String {
        switch self {
        case .skills: "技能"
        case .voice: "语音输入"
        }
    }
    var description: String {
        switch self {
        case .skills: "技能目录、自动发现与执行属于下一批运行层接入。当前可通过 / 菜单使用文本命令；本入口不会加载或执行本地技能。"
        case .voice: "语音识别尚未接入。本入口不会启用麦克风或申请权限；请继续输入文字。"
        }
    }
}

struct AIChatCapabilityInfoView: View {
    let feature: AIChatCapabilityInfo
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(feature.title).font(.headline)
            Text("基础入口 · 尚未接入").font(.caption).foregroundStyle(.secondary)
            Text(feature.description).font(.body)
            HStack { Spacer(); Button("好") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 420)
    }
}
