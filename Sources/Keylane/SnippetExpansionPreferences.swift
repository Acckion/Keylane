import AppKit
import KeylaneCore
import SwiftUI
import UniformTypeIdentifiers

struct SnippetExpansionOptions: Codable, Equatable {
    enum InjectionDelay: String, CaseIterable, Codable {
        case none, short, regular, long, extraLong
        var title: String {
            switch self {
            case .none: "无"
            case .short: "短"
            case .regular: "标准"
            case .long: "长"
            case .extraLong: "超长"
            }
        }

        var seconds: TimeInterval {
            switch self {
            case .none: 0
            case .short: 0.15
            case .regular: 0.3
            case .long: 0.5
            case .extraLong: 0.75
            }
        }
    }

    enum ResponseTime: String, CaseIterable, Codable {
        case instant, quick, standard, delayed, extended
        var title: String {
            switch self {
            case .instant: "即时"
            case .quick: "快速"
            case .standard: "默认"
            case .delayed: "延迟"
            case .extended: "延长"
            }
        }

        var seconds: TimeInterval {
            switch self {
            case .instant: 0.01
            case .quick: 0.02
            case .standard: 0.035
            case .delayed: 0.08
            case .extended: 0.15
            }
        }
    }

    struct Application: Identifiable, Codable, Equatable {
        let id: String
        let name: String
    }

    enum PrimaryAction: String, Codable { case paste, copy }
    static let defaultsKey = "snippets.expansionOptions"
    static let sounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
                         "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    var mode: SnippetExpansionMode = .immediately
    var withinWords = false
    var overrideSystem = false
    var delay: InjectionDelay = .none
    var response: ResponseTime = .standard
    var sound = ""
    var excluded = [Application(id: "com.1password.1password", name: "1Password"),
                    Application(id: "com.apple.keychainaccess", name: "钥匙串访问"),
                    Application(id: "com.apple.Passwords", name: "密码")]
    var warnOnDelete = true
    var primary: PrimaryAction = .paste

    static func load(_ defaults: UserDefaults) -> Self {
        if let data = defaults.data(forKey: defaultsKey), let value = try? JSONDecoder().decode(Self.self, from: data) {
            return value
        }
        var options = Self()
        if defaults.object(forKey: "snippets.expandsKeywords") != nil { options.mode = .keepDelimiter }
        return options
    }

    func excludes(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return excluded.contains { $0.id.caseInsensitiveCompare(identifier) == .orderedSame }
    }
}

struct SnippetPreferences: View {
    let model: Model
    @ObservedObject var controller: SnippetsController
    let expansionPermission: PermissionFeature
    @StateObject private var commandObservation: ViewObservation

    init(model: Model, controller: SnippetsController, expansionPermission: PermissionFeature) {
        self.model = model
        self.controller = controller
        self.expansionPermission = expansionPermission
        _commandObservation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$aliases), ViewObservation.changes(model.$bindings),
            ViewObservation.changes(model.$disabledCommands)
        ]))
    }

    var body: some View {
        SettingsPageSections {
            SettingsSectionTitle(title: "片段展开").settingsAnchor(.snippetExpansion)
            SettingsGroup {
                SettingsPermissionToggle(contribution: expansionPermission.titlebar("启用片段展开"), detail: nil)
                Divider().opacity(0.4)
                settingsChoices
                    .disabled(!controller.expandsKeywords)
                    .opacity(controller.expandsKeywords ? 1 : 0.55)
                Divider().opacity(0.4)
                SettingsRow("删除片段前显示警告") {
                    Toggle("删除片段前显示警告", isOn: $controller.options.warnOnDelete).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }

            SettingsSectionTitle(title: "命令")
            CommandSettingsList(items: SnippetsModule.Command.allCases, id: \.rawValue) { command in
                var entry = CommandSettingsEntry(title: command.title, model: model, commandID: command.id,
                                                 isEnabled: Binding(get: { !model.disabledCommands.contains(command.rawValue) }, set: {
                    if $0 { model.disabledCommands.remove(command.rawValue) }
                    else { model.disabledCommands.insert(command.rawValue) }
                }), perform: {
                    if command == .search { model.settingsPage = SnippetsModule.searchSettingsID }
                    else { model.runCommand(command.id, origin: .menu) }
                }) {
                    SettingsIcon(symbol: command.symbol, artwork: ModuleArtwork.settings("snippets"))
                }
                entry.showsDisclosure = command == .search
                return entry
            }
        }
    }

    @ViewBuilder private var settingsChoices: some View {
        SnippetSettingMenu("展开模式", value: $controller.options.mode, values: SnippetExpansionMode.allCases,
                           title: { mode in
            switch mode {
            case .immediately: "立即"
            case .keepDelimiter: "输入分隔符后（保留）"
            case .discardDelimiter: "输入分隔符后（舍弃）"
            }
        }, help: { mode in
            switch mode {
            case .immediately: "匹配关键词时展开。"
            case .keepDelimiter: "等候空格或标点，并保留这个字符。"
            case .discardDelimiter: "等候空格或标点，展开后移除这个字符。"
            }
        })
        Divider().opacity(0.4)
        SettingsRow("在单词内部展开", detail: "允许关键词作为更长单词的一部分。关闭时，只匹配独立关键词。") {
            Toggle("在单词内部展开", isOn: $controller.options.withinWords).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        Divider().opacity(0.4)
        SettingsRow("优先于系统文本替换", detail: "开启后，Keylane 优先处理与 macOS 文本替换相同的关键词。") {
            Toggle("优先于系统文本替换", isOn: $controller.options.overrideSystem).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        Divider().opacity(0.4)
        SnippetSettingMenu("注入延迟", detail: "匹配后等待再替换。继续输入可以取消展开，也能输入前缀相同的较长关键词。",
                           value: $controller.options.delay, values: SnippetExpansionOptions.InjectionDelay.allCases,
                           title: \.title)
        Divider().opacity(0.4)
        SnippetSettingMenu("响应时间", detail: "控制接收输入后读取剪贴板和检查目标应用的时间。目标应用处理较慢时可增加等待。",
                           value: $controller.options.response, values: SnippetExpansionOptions.ResponseTime.allCases,
                           title: \.title)
        Divider().opacity(0.4)
        SnippetSettingMenu("完成音效", detail: "在片段自动展开后播放。",
                           value: $controller.options.sound, values: [""] + SnippetExpansionOptions.sounds,
                           title: { $0.isEmpty ? "无" : $0 }, choose: { name in
            if !name.isEmpty { NSSound(named: name)?.play() }
        })
        Divider().opacity(0.4)
        SettingsRow("禁用的应用", detail: "在这些应用里暂停关键词展开。") {
            SettingsIconButton("添加应用", symbol: "plus", action: addApplication)
        }
        if !controller.options.excluded.isEmpty {
            SettingsCompactList(items: controller.options.excluded, id: \.id) { app in
                SettingsCompactItemRow(title: app.name, symbol: "app") {
                    SettingsRemoveItemButton(label: "移除应用", help: app.name) {
                        controller.options.excluded.removeAll { $0.id == app.id }
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func addApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
                  !controller.options.excludes(identifier) else { continue }
            let name = FileManager.default.displayName(atPath: url.path)
            controller.options.excluded.append(.init(id: identifier, name: name))
        }
    }
}

struct SnippetSearchPreferences: View {
    @ObservedObject var controller: SnippetsController

    var body: some View {
        SettingsPageSections {
            SettingsGroup {
                SettingsPicker("主要操作", selection: $controller.options.primary) {
                    Text("粘贴到当前应用").tag(SnippetExpansionOptions.PrimaryAction.paste)
                    Text("复制到剪贴板").tag(SnippetExpansionOptions.PrimaryAction.copy)
                }
            }
            .settingsAnchor(.snippetSearchCommand)
        }
    }
}

private struct SnippetSettingMenu<Value: Hashable>: View {
    let name: String
    var detail: String? = nil
    @Binding var value: Value
    let values: [Value]
    let title: (Value) -> String
    var help: ((Value) -> String)? = nil
    var choose: (Value) -> Void = { _ in }
    @State private var open = false
    @State private var query = ""
    @State private var expanded = false
    private var expandable: Bool { detail.map { $0.count > 32 } ?? false }

    init(_ name: String, detail: String? = nil, value: Binding<Value>, values: [Value],
         title: @escaping (Value) -> String, help: ((Value) -> String)? = nil, choose: @escaping (Value) -> Void = { _ in }) {
        self.name = name
        self.detail = detail
        self._value = value
        self.values = values
        self.title = title
        self.help = help
        self.choose = choose
    }

    var body: some View {
        SettingsRow {
            if let detail {
                VStack(alignment: .leading, spacing: 3) {
                    SettingsTitle(name)
                    SettingsDescription(detail).lineLimit(expandable && !expanded ? 1 : nil)
                    if expandable {
                        Button(expanded ? "收起" : "显示更多") { expanded.toggle() }
                            .font(.system(size: 12, weight: .medium)).buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            } else { SettingsTitle(name) }
        } control: {
            Button {
                query = ""
                open.toggle()
            } label: {
                HStack(spacing: 10) {
                    Text(title(value))
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel(name)
            .accessibilityValue(title(value))
            .popover(isPresented: $open, arrowEdge: .bottom) {
                let options = values.enumerated().map { index, option in
                    ResultFilterOption(id: String(index), title: title(option), symbol: "", help: help?(option))
                }
                ResultFilterPanel(selection: values.firstIndex(of: value).map(String.init) ?? "",
                                  options: ResultFilterPanel.matches(options, query: query),
                                  query: $query, searchPlaceholder: "搜索…", emptyTitle: "没有匹配选项",
                                  width: help == nil ? 220 : 274, choose: { option in
                    guard let index = Int(option.id), values.indices.contains(index) else { return }
                    open = false
                    value = values[index]
                    choose(value)
                }, dismiss: { open = false })
            }
        }
    }
}
