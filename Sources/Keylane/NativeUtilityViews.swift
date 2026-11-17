import SwiftUI
import AppKit
import Contacts
import KeylaneCore

struct SystemShortcutsPreferences: View {
    let model: Model
    @StateObject private var observation: ViewObservation
    let controller: SystemShortcutsController
    @ObservedObject var search: SettingsSearchControls

    init(model: Model, controller: SystemShortcutsController, search: SettingsSearchControls) {
        self.model = model
        self.controller = controller
        self.search = search
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$aliases),
            ViewObservation.changes(model.$bindings),
            ViewObservation.changes(controller.$entries),
            ViewObservation.changes(controller.$folders),
            ViewObservation.changes(controller.$loading),
            ViewObservation.changes(controller.$message),
            ViewObservation.changes(controller.$executionMessage),
            ViewObservation.changes(controller.$icons),
            ViewObservation.changes(controller.$disabledIDs)
        ]))
    }

    var body: some View {
        SettingsPageSections {
            if (!controller.loading && controller.entries.isEmpty) || !controller.executionMessage.isEmpty || !controller.message.isEmpty {
                SettingsGroup {
                    if !controller.executionMessage.isEmpty { SettingsDescription(controller.executionMessage) }
                    if !controller.message.isEmpty { Text(controller.message).foregroundStyle(.secondary) }
                    if !controller.loading, controller.entries.isEmpty, controller.message.isEmpty {
                        Text("系统中没有快捷指令").foregroundStyle(.secondary)
                    }
                }
            }
            if !controller.entries.isEmpty { shortcutLists }
        }.settingsAnchor(.systemShortcuts).task {
            controller.refresh(force: true)
            controller.refreshFolders()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
                controller.refresh()
                controller.refreshFolders()
            }
        }.onDisappear(perform: controller.stopFolderRefresh)
    }

    @ViewBuilder private var shortcutLists: some View {
        let query = search.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let folders = controller.folders {
            let sections = SystemShortcutFolder.sections(folders, shortcuts: controller.entries)
            let visible = sections.compactMap { section -> (section: SystemShortcutFolder.Section, rows: [SystemShortcut])? in
                let rows = query.isEmpty || section.name.localizedCaseInsensitiveContains(query)
                    ? section.shortcuts : section.shortcuts.filter { matches($0, query: query) }
                return rows.isEmpty ? nil : (section, rows)
            }
            if visible.isEmpty { CommandSettingsEmptyState(message: "没有匹配的快捷指令") }
            ForEach(visible, id: \.section.id) { group in
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionTitle(title: group.section.name)
                    shortcutList(group.rows)
                }
            }
        } else {
            shortcutList(controller.entries.filter { matches($0, query: query) })
        }
    }

    private func matches(_ shortcut: SystemShortcut, query: String) -> Bool {
        query.isEmpty || shortcut.name.localizedCaseInsensitiveContains(query)
            || model.aliases[shortcut.commandID]?.localizedCaseInsensitiveContains(query) == true
    }

    private func shortcutList(_ shortcuts: [SystemShortcut]) -> some View {
        CommandSettingsList(items: shortcuts, id: \.id, emptyMessage: "没有匹配的快捷指令") {
            $0.commandSettingsEntry(model: model, controller: controller)
        }
    }
}

extension SystemShortcut {
    func commandSettingsEntry(model: Model, controller: SystemShortcutsController) -> CommandSettingsEntry<ShortcutArtwork> {
        CommandSettingsEntry(
            title: controller.duplicateTitles.contains(name) ? "\(name) · \(identifierSuffix)" : name,
            model: model, commandID: .init(rawValue: commandID),
            isEnabled: Binding(get: { !controller.disabledIDs.contains(id) }, set: { enabled in
                if enabled { controller.disabledIDs.remove(id) }
                else { controller.disabledIDs.insert(id) }
            }),
            perform: { model.runCommand(.init(rawValue: commandID), origin: .menu) },
            icon: { ShortcutArtwork(image: controller.icons[id]) }
        )
    }
}

struct ContactsPage: View {
    @ObservedObject var controller: ContactsController
    let permission: PermissionFeature
    let showSettings: () -> Void
    @State private var permissionEnabled = false
    @State private var permissionStatus = SettingsPermissionStatus()

    var body: some View {
        ResultDetailLayout(hasResults: permissionEnabled && controller.canRead
                           && controller.error.isEmpty && !controller.visible.isEmpty) {
            SelectableResultList(selection: controller.selectedID) {
                ForEach(controller.visible) { contact in
                    ResultListButton(id: contact.id, action: { controller.select(contact.id) }) {
                        ResultListRow(selected: contact.id == controller.selectedID) {
                            Image(systemName: "person.crop.circle.fill").font(.system(size: 23)).foregroundStyle(.blue)
                        } content: {
                            VStack(alignment: .leading, spacing: 2) {
                                HighlightedResultText(text: contact.name, query: controller.query)
                                    .font(VisualStyle.rowText).lineLimit(1)
                                if !contact.listDetail.isEmpty {
                                    HighlightedResultText(text: contact.listDetail, query: controller.query)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
        } detail: {
            if let contact = controller.selected {
                ResultDetailPane { _ in
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 66)).foregroundStyle(.blue)
                        Text(contact.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                        if !contact.organization.isEmpty { Text(contact.organization).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity)
                } information: {
                    DetailInformationSection(rows: contact.phones.enumerated().map {
                        .init(title: $0.offset == 0 ? "电话" : "电话 \($0.offset + 1)", value: $0.element)
                    } + contact.emails.enumerated().map {
                        .init(title: $0.offset == 0 ? "邮箱" : "邮箱 \($0.offset + 1)", value: $0.element)
                    })
                    if contact.firstValue == nil { Text("没有电话或邮箱").foregroundStyle(.secondary).font(.caption) }
                }
            }
        } emptyState: {
            if !permissionEnabled {
                ContentUnavailableView {
                    Label(permissionStatus.message == nil ? "联系人已关闭" : "联系人访问不可用",
                          systemImage: "person.crop.circle")
                } description: {
                    if let message = permissionStatus.message { Text(message) }
                } actions: {
                    Button("联系人设置…", action: showSettings).buttonStyle(ContentActionButtonStyle())
                }
            } else if !controller.canRead {
                connection
            } else if !controller.error.isEmpty {
                ContentUnavailableView {
                    Label("联系人读取失败", systemImage: "exclamationmark.triangle")
                } description: { Text(controller.error) } actions: {
                    Button("重试") { controller.refresh() }.buttonStyle(ContentActionButtonStyle())
                }
            } else if controller.loading {
                Text("正在读取联系人…").font(VisualStyle.rowText).foregroundStyle(.secondary)
            } else {
                ResultDetailEmptyState(title: "没有匹配联系人")
            }
        }
        .onReceive(permission.$enabled) { permissionEnabled = $0 }
        .onReceive(permission.settingsStatus) { permissionStatus = $0 }
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
