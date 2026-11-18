import SwiftUI

struct AIModelCatalogSettings: View {
    @ObservedObject var configuration: AIConfiguration
    let edit: (AIConnection) -> Void
    @State private var query = ""
    @State private var groupByBrand = false

    var body: some View {
        SettingsPageSections {
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
                    AIModelProviderGroup(provider: provider, connections: connections.sorted {
                        $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                    }, forceExpanded: !query.isEmpty, configuration: configuration, edit: edit)
                }
            }
            if filtered.isEmpty { SettingsListEmptyState(title: "没有匹配的模型。") }
        }
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

private struct AIModelProviderGroup: View {
    let provider: String
    let connections: [AIConnection]
    let forceExpanded: Bool
    @ObservedObject var configuration: AIConfiguration
    let edit: (AIConnection) -> Void
    @State private var expanded = false
    @State private var opened = false
    private var isExpanded: Bool { expanded || forceExpanded }

    var body: some View {
        SettingsCard(layout: .flush) {
            VStack(spacing: 0) {
                SettingsDisclosureRow(title: "\(provider) · \(connections.count)", expanded: Binding(
                    get: { isExpanded }, set: { expanded = $0; if $0 { opened = true } }
                ))
                .frame(minHeight: SettingsRowsLayout.rowHeight)
                .padding(.vertical, 4)
                if opened || forceExpanded {
                    VStack(spacing: 0) {
                        modelColumns
                        if connections.count <= 40 {
                            VStack(spacing: 0) { rows }
                        } else {
                            LazyVStack(spacing: 0) { rows }
                        }
                    }
                    .frame(height: isExpanded ? nil : 0, alignment: .top)
                    .clipped().opacity(isExpanded ? 1 : 0)
                    .allowsHitTesting(isExpanded).accessibilityHidden(!isExpanded)
                }
            }.padding(.horizontal, 18)
        }
    }

    private var rows: some View {
        ForEach(connections) { connection in
            modelRow(connection)
            if connection.id != connections.last?.id { Divider().opacity(0.4) }
        }
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
