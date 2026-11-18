import SwiftUI

struct AIModelCatalogSettings: View {
    @ObservedObject var configuration: AIConfiguration
    let edit: (AIConnection) -> Void
    @State private var expanded = Set<String>()
    @State private var query = ""
    @State private var groupByBrand = false

    private enum Choice: Hashable {
        case shared, lastUsed, connection(UUID)
    }

    var body: some View {
        SettingsPageSections {
            SettingsGroup("默认模型") {
                ForEach(AIRoute.allCases) { route in
                    if route != .quick { Divider() }
                    defaults(for: route)
                }
            }
            SettingsGroup {
                SettingsPicker("管理模型", selection: $groupByBrand) {
                    Text("按提供商分组").tag(false)
                    Text("按品牌分组").tag(true)
                }
                Divider()
                SettingsRow("搜索模型") {
                    TextField("名称、模型 ID 或提供商", text: $query).frame(width: 250)
                }
            }
            let filtered = configuration.state.connections.filter {
                query.isEmpty || ($0.displayName + " " + $0.model + " " + $0.providerLabel).localizedCaseInsensitiveContains(query)
            }
            let byProvider = Dictionary(grouping: filtered, by: { groupByBrand ? brand($0) : $0.providerLabel })
            ForEach(byProvider.keys.sorted(), id: \.self) { provider in
                if let connections = byProvider[provider] {
                    SettingsCard(layout: .flush) {
                        VStack(spacing: 0) {
                            SettingsDisclosureRow(title: "\(provider) · \(connections.count)", expanded: Binding(
                                get: { expanded.contains(provider) || !query.isEmpty },
                                set: { if $0 { expanded.insert(provider) } else { expanded.remove(provider) } }
                            ))
                            if expanded.contains(provider) || !query.isEmpty {
                                modelColumns
                                LazyVStack(spacing: 0) {
                                    ForEach(connections.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) { connection in
                                        modelRow(connection)
                                        if connection.id != connections.last?.id { Divider().opacity(0.4) }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                    }
                }
            }
            if filtered.isEmpty { SettingsListEmptyState(title: "没有匹配的模型。") }
        }
    }

    private func defaults(for route: AIRoute) -> some View {
        let current = choice(for: route)
        let selected = configuration.state.defaults?[route]
        let connections = configuration.state.connections.filter {
            $0.isConfigured && ($0.hiddenFromPicker != true || $0.id == selected)
        }
        let resolved = configuration.state.connection(for: route)
        let detail = resolved.map { "\($0.model) · \($0.destinationLabel)" }
            ?? (configuration.state.enabled ? "此入口的默认连接不可用，请选择可用连接。" : nil)
        return SettingsPicker(route.title, detail: detail, selection: Binding(get: { choice(for: route) }, set: { value in
            switch value {
            case .shared: configuration.setDefault(nil, for: route)
            case .lastUsed: configuration.setDefault(nil, for: route, usesLastChatModel: true)
            case .connection(let id): configuration.setDefault(id, for: route)
            }
        })) {
            Text("跟随共用连接").tag(Choice.shared)
            if route == .chat { Text("上次使用的模型").tag(Choice.lastUsed) }
            if case .connection(let id) = current, !connections.contains(where: { $0.id == id }) {
                Text("原连接不可用").tag(current)
            }
            ForEach(connections) { connection in
                Text("\(connection.displayName) · \(connection.providerLabel)").tag(Choice.connection(connection.id))
            }
        }
    }

    private func choice(for route: AIRoute) -> Choice {
        if route == .chat && configuration.state.usesLastChatModel == true { return .lastUsed }
        return configuration.state.defaults?[route].map(Choice.connection) ?? .shared
    }

    private func description(for connection: AIConnection) -> String {
        var details = [connection.model]
        if let tokens = connection.contextTokens {
            details.append("已登记上下文 \(tokens.formatted()) tokens")
        }
        if connection.supportsImages == true { details.append("图像") }
        if connection.supportsTools == true { details.append("工具") }
        if connection.hiddenFromPicker == true { details.append("已从默认模型选项隐藏") }
        return details.joined(separator: " · ")
    }

    private var modelColumns: some View {
        HStack {
            SettingsDescription("模型").frame(maxWidth: .infinity, alignment: .leading)
            SettingsDescription("速度").frame(width: 52)
            SettingsDescription("智能程度").frame(width: 65)
            SettingsDescription("上下文").frame(width: 70)
            Color.clear.frame(width: 22)
        }.padding(.vertical, 10)
    }

    private func modelRow(_ connection: AIConnection) -> some View {
        HStack(spacing: 8) {
            Button { edit(connection) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    SettingsTitle(connection.displayName)
                    SettingsDescription(connection.providerLabel).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(description(for: connection))
            Text("—").foregroundStyle(.secondary).frame(width: 52).help("尚无可靠速度评分")
            Text("—").foregroundStyle(.secondary).frame(width: 65).help("尚无可靠智能程度评分")
            Text(connection.contextTokens.map { $0.formatted(.number.notation(.compactName)) } ?? "—")
                .foregroundStyle(.secondary).frame(width: 70)
            Toggle("显示 \(connection.displayName)", isOn: Binding(
                get: { connection.hiddenFromPicker != true },
                set: { configuration.setModelVisible(connection.id, visible: $0) }
            )).labelsHidden().toggleStyle(.checkbox).frame(width: 22)
        }.padding(.vertical, 12)
    }

    private func brand(_ connection: AIConnection) -> String {
        let model = connection.model.lowercased()
        for (prefix, name) in [("gpt", "OpenAI"), ("o3", "OpenAI"), ("o4", "OpenAI"),
                               ("claude", "Anthropic"), ("gemini", "Google"), ("qwen", "Alibaba"),
                               ("deepseek", "DeepSeek"), ("glm", "Z.AI"), ("grok", "xAI"),
                               ("mistral", "Mistral"), ("llama", "Meta")] {
            if model.hasPrefix(prefix) || model.contains("/" + prefix) { return name }
        }
        return "其他 · " + connection.providerLabel
    }
}

struct AIModelDiscoveryList: View {
    let models: [String]
    let choose: (String) -> Void
    var chooseAll: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsTitle("提供方模型")
            TextField("搜索模型 ID", text: $query)
            let matches = models.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
            if matches.isEmpty {
                SettingsDescription("没有匹配的模型。")
            }
            List(matches, id: \.self) { model in
                Button {
                    choose(model)
                    dismiss()
                } label: {
                    Text(model).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            HStack {
                if let chooseAll { Button("加入全部模型") { chooseAll(); dismiss() } }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 460, height: 360)
    }
}
