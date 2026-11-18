import SwiftUI

enum AIModelChoice: Hashable {
    case model(UUID), lastUsed, inherit
}

/// Shared searchable model menu for every AI surface. Special choices belong to
/// the calling surface; models, visibility, keyboard handling and metadata do not.
struct AIModelPicker: View {
    @ObservedObject var configuration: AIConfiguration
    @Binding var selection: AIModelChoice
    var inheritTitle: String? = nil
    var allowsLastUsed = false
    @State private var showing = false

    private var title: String {
        switch selection {
        case .lastUsed: "上次使用的模型"
        case .inherit: inheritTitle ?? "尚未选择模型"
        case .model(let id): configuration.state.connections.first { $0.id == id }?.displayName ?? "原模型不可用"
        }
    }

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 6) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.caption)
            }.frame(maxWidth: 240, alignment: .trailing)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("选择模型：" + title)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            AIModelMenu(configuration: configuration, selection: $selection, inheritTitle: inheritTitle,
                        allowsLastUsed: allowsLastUsed) { showing = false }
        }
    }
}

private struct AIModelMenu: View {
    @ObservedObject var configuration: AIConfiguration
    @Binding var selection: AIModelChoice
    let inheritTitle: String?
    let allowsLastUsed: Bool
    let close: () -> Void
    @State private var query = ""
    @State private var highlighted: AIModelChoice?
    @FocusState private var searchFocused: Bool

    private var models: [AIConnection] {
        configuration.state.connections.filter {
            ($0.isConfigured && $0.hiddenFromPicker != true || selection == .model($0.id)) &&
                (query.isEmpty || ($0.displayName + " " + $0.model + " " + $0.providerLabel).localizedCaseInsensitiveContains(query))
        }.sorted {
            $0.providerLabel == $1.providerLabel
                ? $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                : $0.providerLabel.localizedStandardCompare($1.providerLabel) == .orderedAscending
        }
    }
    private var choices: [AIModelChoice] {
        (inheritTitle == nil ? [] : [.inherit]) + (allowsLastUsed ? [.lastUsed] : []) + models.filter(\.isConfigured).map { .model($0.id) }
    }
    private var inspected: AIConnection? {
        guard case .model(let id) = highlighted ?? selection else { return nil }
        return configuration.state.connections.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("搜索模型、提供商…", text: $query).textFieldStyle(.plain)
                .focused($searchFocused).padding(14)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            if let inheritTitle { row(.inherit, title: inheritTitle, symbol: "arrow.turn.down.right") }
                            if allowsLastUsed { row(.lastUsed, title: "上次使用的模型", symbol: "clock") }
                            if models.isEmpty { SettingsDescription("没有匹配的可用模型").padding(12) }
                            let groups = Dictionary(grouping: models, by: \.providerLabel)
                            ForEach(groups.keys.sorted(), id: \.self) { provider in
                                SettingsDescription(provider).padding(.top, 10).padding(.horizontal, 10)
                                ForEach(groups[provider] ?? []) { model in
                                    row(.model(model.id), title: model.displayName, subtitle: model.model,
                                        enabled: model.isConfigured)
                                }
                            }
                        }.padding(8)
                    }.frame(width: 330, height: 320)
                        .onChange(of: highlighted) { _, choice in if let choice { reader.scrollTo(choice, anchor: .center) } }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    if let model = inspected {
                        SettingsTitle(model.displayName)
                        SettingsDescription(model.providerLabel)
                        Divider()
                        SettingsDescription(model.contextTokens.map { "上下文：\($0.formatted()) tokens" } ?? "上下文：未提供")
                        SettingsDescription(capability("图像输入", model.supportsImages))
                        SettingsDescription(capability("工具调用", model.supportsTools))
                        if !model.isConfigured { SettingsDescription("连接不可用，请先检查提供商设置。") }
                    } else {
                        SettingsDescription("选择模型查看已登记的能力。")
                    }
                }.padding(14).frame(width: 190, alignment: .leading)
            }
        }
        .frame(width: 535)
        .onAppear { highlighted = selection; searchFocused = true }
        .onChange(of: query) { _, _ in highlighted = choices.first }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) {
            guard let highlighted, choices.contains(highlighted) else { return .ignored }
            selection = highlighted; close(); return .handled
        }
        .onKeyPress(.escape) { close(); return .handled }
    }

    private func capability(_ title: String, _ supported: Bool?) -> String {
        title + "：" + (supported.map { $0 ? "支持" : "不支持" } ?? "未提供")
    }
    private func move(_ step: Int) {
        let options = choices
        guard !options.isEmpty else { return }
        let index = highlighted.flatMap { options.firstIndex(of: $0) } ?? (step > 0 ? -1 : options.count)
        highlighted = options[min(options.count - 1, max(0, index + step))]
    }
    private func row(_ choice: AIModelChoice, title: String, subtitle: String? = nil,
                     symbol: String = "sparkles", enabled: Bool = true) -> some View {
        Button { selection = choice; close() } label: {
            HStack(spacing: 8) {
                Image(systemName: selection == choice ? "checkmark.circle.fill" : symbol)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    SettingsTitle(title).lineLimit(1)
                    if let subtitle { SettingsDescription(subtitle).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }.padding(8).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .background(.primary.opacity(highlighted == choice ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).id(choice)
        .onHover { if $0 { highlighted = choice } }
    }
}

struct AIModelDefaultsSettings: View {
    @ObservedObject var configuration: AIConfiguration
    var body: some View {
        SettingsGroup("默认模型") {
            ForEach(AIRoute.allCases) { route in
                if route != .quick { Divider() }
                let resolved = configuration.state.connection(for: route)
                SettingsRow(route.title, detail: resolved?.model) {
                    AIModelPicker(configuration: configuration, selection: Binding(
                        get: {
                            if route == .chat && configuration.state.usesLastChatModel == true { return .lastUsed }
                            return (configuration.state.defaults?[route] ?? configuration.state.selectedID).map(AIModelChoice.model) ?? .inherit
                        }, set: {
                            switch $0 {
                            case .model(let id): configuration.setDefault(id, for: route)
                            case .lastUsed: configuration.setDefault(nil, for: .chat, usesLastChatModel: true)
                            case .inherit: break
                            }
                        }), allowsLastUsed: route == .chat)
                }
            }
        }
    }
}
