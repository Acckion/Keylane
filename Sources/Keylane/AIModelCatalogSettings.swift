import SwiftUI

struct AIModelCatalogSettings: View {
    @ObservedObject var configuration: AIConfiguration
    let edit: (AIConnection) -> Void

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
            let byProvider = Dictionary(grouping: configuration.state.connections, by: \.providerLabel)
            ForEach(byProvider.keys.sorted(), id: \.self) { provider in
                if let connections = byProvider[provider] {
                    SettingsGroup(provider) {
                        ForEach(connections) { connection in
                            if connection.id != connections.first?.id { Divider() }
                            Button { edit(connection) } label: {
                                SettingsRow(connection.displayName, detail: description(for: connection)) {
                                    Image(systemName: "chevron.forward").imageScale(.small).foregroundStyle(.secondary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func defaults(for route: AIRoute) -> some View {
        let current = choice(for: route)
        let selected = configuration.state.defaults?[route]
        let connections = configuration.state.connections.filter {
            $0.isConfigured && ($0.hiddenFromPicker != true || $0.id == selected)
        }
        let resolved = configuration.state.connection(for: route)
        let detail = resolved?.completionURL.map { "\(resolved?.model ?? "") · \($0.absoluteString)" }
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
}

struct AIModelDiscoveryList: View {
    let models: [String]
    let choose: (String) -> Void
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
            Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(18)
        .frame(width: 460, height: 360)
    }
}
