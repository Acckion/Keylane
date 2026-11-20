import SwiftUI

/// Explicit scaffolding: these controls do not advertise or grant tool access.
struct AIChatCapabilitySection: View {
    @State private var information: AIChatCapabilityInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("扩展工具", symbol: "puzzlepiece.extension", feature: .tools,
                    detail: "可手动添加文件、剪贴板和日程。AI 自动调用工具尚未接入。")
            section("技能", symbol: "square.stack.3d.up", feature: .skills,
                    detail: "技能发现与执行尚未接入，不会加载本地脚本。")
            VStack(alignment: .leading, spacing: 6) {
                Text("工具权限").font(.subheadline)
                Text("工具运行层接入后提供逐次确认与权限策略。").font(.caption).foregroundStyle(.secondary)
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
    case tools, skills, voice
    var id: Self { self }
    var title: String {
        switch self {
        case .tools: "扩展工具"
        case .skills: "技能"
        case .voice: "语音输入"
        }
    }
    var description: String {
        switch self {
        case .tools: "当前支持用户手动选择上下文。模型自动调用扩展工具、操作系统和执行轨迹尚未接入，本入口不会运行命令或获取额外权限。"
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
