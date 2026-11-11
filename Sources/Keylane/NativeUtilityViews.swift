import SwiftUI
import AppKit
import Contacts
import KeylaneCore

struct SystemShortcutsPreferences: View {
    @ObservedObject var model: Model
    @ObservedObject var controller: SystemShortcutsController
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 16) {
            SettingsGroup {
                HStack {
                    TextField("查找快捷指令…", text: $filter).textFieldStyle(.plain)
                    Button("刷新", systemImage: "arrow.clockwise") { controller.refresh(force: true) }.disabled(controller.loading)
                    Button("打开快捷指令") { UtilityActions.openApplication("com.apple.shortcuts") }
                }.buttonStyle(ContentActionButtonStyle())
                if controller.loading { ProgressView().controlSize(.small) }
                if !controller.entries.isEmpty { iconAccessRow }
                if !controller.message.isEmpty { Text(controller.message).foregroundStyle(.secondary) }
                if !controller.loading, controller.entries.isEmpty, controller.message.isEmpty { Text("系统中没有快捷指令").foregroundStyle(.secondary) }
            }.id("system-shortcuts")
            if !controller.entries.isEmpty {
                SettingsGroup {
                    ForEach(controller.entries.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) { entry in
                        CommandSettingsRow(title: entry.name,
                            alias: Binding(get: { model.aliases[entry.commandID] ?? "" }, set: { model.setAlias(entry.commandID, value: $0) }),
                            shortcut: model.bindings[entry.commandID],
                            isEnabled: Binding(get: { !controller.disabledIDs.contains(entry.id) }, set: { enabled in
                                if enabled { controller.disabledIDs.remove(entry.id) } else { controller.disabledIDs.insert(entry.id) }
                            }),
                            setShortcut: { model.setShortcut(entry.commandID, value: $0) },
                            icon: { ShortcutArtwork(image: controller.icons[entry.id]) },
                            perform: { controller.run(entry.id) })
                    }
                }
            }
        }.onAppear { controller.refresh(force: true) }
    }

    @ViewBuilder private var iconAccessRow: some View {
        switch controller.iconAccess {
        case .inactive, .denied, .unavailable:
            HStack {
                Text(controller.iconAccess == .denied ? "请在「隐私与安全性 → 自动化」允许 Keylane 访问快捷指令。" :
                    "允许访问后显示每条指令在 Apple 快捷指令中的原始图标。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("读取原始图标") { controller.refreshIcons(requestAccess: true) }
                    .buttonStyle(ContentActionButtonStyle())
            }
        case .loading:
            ProgressView("正在读取图标…").controlSize(.small)
        case .allowed:
            EmptyView()
        }
    }
}

struct ContactsPage: View {
    @ObservedObject var controller: ContactsController
    var body: some View {
        ResultDetailLayout {
            ScrollViewReader { proxy in
                ResultListScrollView {
                    ForEach(controller.visible) { contact in
                        Button { controller.select(contact.id) } label: {
                            ResultListRow(selected: contact.id == controller.selectedID) {
                                Image(systemName: "person.crop.circle.fill").font(.system(size: 23)).foregroundStyle(.blue)
                            } content: {
                                HighlightedResultText(text: contact.name, query: controller.query).font(VisualStyle.rowText).lineLimit(1)
                            }
                        }.buttonStyle(.plain).id(contact.id)
                    }
                }.onChange(of: controller.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
            }
        } detail: {
            Group {
                if !controller.canRead { connection }
                else if !controller.error.isEmpty {
                    ContentUnavailableView {
                        Label("联系人读取失败", systemImage: "exclamationmark.triangle")
                    } description: { Text(controller.error) } actions: {
                        Button("重试") { controller.refresh() }.buttonStyle(ContentActionButtonStyle())
                    }
                } else if let contact = controller.selected {
                    ResultDetailPane {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill").font(.system(size: 66)).foregroundStyle(.blue)
                            Text(contact.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                            if !contact.organization.isEmpty { Text(contact.organization).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } information: {
                        DetailInformationSection(rows: contact.phones.enumerated().map {
                            .init(title: $0.offset == 0 ? "电话" : "电话 \($0.offset + 1)", value: $0.element)
                        } + contact.emails.enumerated().map {
                            .init(title: $0.offset == 0 ? "邮箱" : "邮箱 \($0.offset + 1)", value: $0.element)
                        })
                        if contact.firstValue == nil { Text("没有电话或邮箱").foregroundStyle(.secondary).font(.caption) }
                    }
                } else if controller.loading {
                    ProgressView("正在读取联系人…")
                } else { ContentUnavailableView("没有匹配联系人", systemImage: "person.crop.circle") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var connection: some View {
        ContentUnavailableView {
            Label("连接联系人", systemImage: "person.crop.circle")
        } description: {
            Text(controller.access == .notDetermined ? "允许访问后，可按姓名、公司、电话或邮箱搜索。" : "请在系统隐私设置中允许 Keylane 访问联系人。")
        } actions: {
            if controller.access == .notDetermined {
                Button(controller.requesting ? "正在等待授权…" : "允许访问…") { controller.requestAccess() }
                    .disabled(controller.requesting).buttonStyle(ContentActionButtonStyle())
            } else {
                Button("打开联系人隐私设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") { NSWorkspace.shared.open(url) }
                }.buttonStyle(ContentActionButtonStyle())
            }
        }
    }
}

struct DictionaryPage: View {
    @ObservedObject var controller: DictionaryController
    var body: some View {
        Group {
            if let definition = controller.definition {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(controller.term).font(.system(size: 23, weight: .semibold))
                        Text(definition).font(VisualStyle.rowText).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
                }
            } else if controller.loading { ProgressView("正在查询…") }
            else if controller.term.isEmpty {
                ContentUnavailableView("输入要查找的词语", systemImage: "book.closed")
            } else {
                ContentUnavailableView("没有找到释义", systemImage: "book.closed", description: Text("试试其他拼写，或检查系统词典中已启用的词库。"))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.top, 61).padding(.bottom, 52)
    }
}
