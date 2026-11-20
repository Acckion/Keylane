import AppKit
import SwiftUI
import Combine
import KeylaneCore

enum FocusModule {
    static let settingsID = "keylane.focus"
    static let categoryPage = PageID(rawValue: "FocusCategoryEditor")
    static let searchPage = PageID(rawValue: "FocusCategories")
    static let sessionPage = PageID(rawValue: "FocusSessionEditor")
    static let importPage = PageID(rawValue: "FocusCategoryImport")
    static func make(model: Model) -> LauncherModule {
        let controller = model.focus
        let back: () -> Void = { [weak model] in model?.pageID = .root }
        let showCategory: (FocusCategory?) -> Void = { [weak model] category in
            controller.prepareCategory(category, duplicate: category.map { item in !controller.archive.categories.contains { $0.id == item.id } } ?? false)
            model?.openPage(categoryPage, origin: .menu)
        }
        let showSession: () -> Void = { [weak model, weak controller] in
            guard let controller else { return }
            controller.prepareSession(editing: controller.session != nil)
            model?.openPage(sessionPage, origin: .menu)
        }
        controller.edit = showSession
        controller.openSettings = { [weak model] in model?.openSettings(page: settingsID) }
        let definitions: [(String, String, String, LauncherCommandDeclaration.Destination, () -> Bool, () -> Void)] = [
            ("focus-start", "开始专注", "Start Focus Session", .page(sessionPage), { true }, { controller.prepareSession(editing: controller.session != nil) }),
            ("focus-toggle", "切换专注", "Toggle Focus Session", .action, { true }, controller.toggle),
            ("focus-complete", "完成专注", "Complete Focus Session", .action, { controller.session != nil }, { controller.finish(completed: true) }),
            ("focus-pause", "暂停专注", "Pause Focus Session", .action, { controller.session?.paused == false }, { controller.pause() }),
            ("focus-resume", "恢复专注", "Resume Focus Session", .action, { controller.session?.paused == true }, controller.resume),
            ("focus-edit", "编辑专注", "Edit Focus Session", .page(sessionPage), { controller.session != nil }, { controller.prepareSession(editing: true) }),
            ("focus-category-create", "创建专注分类", "Create Focus Category", .page(categoryPage), { true }, { controller.prepareCategory() }),
            ("focus-category-search", "搜索专注分类", "Search Focus Categories", .page(searchPage), { true }, {}),
            ("focus-category-import", "导入专注分类", "Import Focus Categories", .page(importPage), { true }, { controller.message = "" })
        ]
        let commands: [LauncherModule.Command] = definitions.map { id, title, english, destination, available, execute in
            .init(declaration: .init(id: .init(rawValue: id), title: title, detail: "Keylane Focus", symbol: "target",
                                     keywords: [english, "Focus", "专注"], destination: destination, settingsPage: settingsID),
                  available: available, permission: controller.permission, execute: { _ in execute() })
        }
        let updates = Publishers.MergeMany([
            ViewObservation.changes(controller.$archive), ViewObservation.changes(controller.$draft),
            ViewObservation.changes(controller.$categoryDraft), ViewObservation.changes(controller.$selectedCategory),
            ViewObservation.changes(controller.$starting)
        ]).eraseToAnyPublisher()
        let acquire: (String) -> String? = { [weak model] _ in model?.acquireApplicationCatalog(for: .focus); return nil }
        let release: () -> Void = { [weak model] in model?.releaseApplicationCatalog(for: .focus) }
        let categoryEditor = LauncherPage(
            id: categoryPage, placeholder: "", badge: ("专注分类", "target"), contentPlacement: .form,
            content: { [weak model] in
                guard let model else { return AnyView(EmptyView()) }
                return AnyView(FocusCategoryForm(controller: controller, catalog: model.applicationSettingsCatalog, back: back).id(controller.categoryDraft.id))
            }, leave: release, keepsStateWhenHidden: true, back: back,
            submit: { [weak model] in if controller.saveCategory() { model?.openPage(searchPage, origin: .menu) } },
            returnBindings: .init(primary: .command), primaryTitle: { controller.editingCategory == nil ? "保存专注分类" : "更新分类" },
            primaryEnabled: { controller.canSaveCategory }, updates: updates, enter: acquire
        )
        let sessionEditor = LauncherPage(
            id: sessionPage, placeholder: "", badge: ("专注", "target"), contentPlacement: .form,
            content: { [weak model] in
                guard let model else { return AnyView(EmptyView()) }
                return AnyView(FocusSessionForm(controller: controller, catalog: model.applicationSettingsCatalog, back: back))
            }, leave: { release(); controller.cancelPreparation() }, keepsStateWhenHidden: true, back: back,
            submit: { controller.saveSession { (NSApp.delegate as? Delegate)?.hideLauncher() } },
            returnBindings: .init(primary: .command), primaryTitle: { controller.starting ? "正在准备…" : controller.editingSession ? "更新专注" : "开始专注" },
            primaryEnabled: { controller.canStart }, updates: updates, enter: acquire
        )
        let search = LauncherPage(
            id: searchPage, placeholder: "搜索专注分类…", badge: ("专注分类", "target"), contentPlacement: .underChrome,
            content: { AnyView(FocusCategoryList(controller: controller, edit: { showCategory($0) })) },
            queryChanged: { controller.categoryQuery = $0; controller.selectedCategory = controller.visibleCategories.first?.id },
            keepsStateWhenHidden: true, back: back, move: controller.moveCategory,
            submit: { if let category = controller.chosenCategory { showCategory(category) } },
            returnBindings: .init(primary: .plain), actionSelectionID: { controller.selectedCategory?.uuidString },
            actionContextTitle: { controller.chosenCategory?.name }, primaryTitle: { controller.isCustomCategory ? "编辑专注分类" : "复制并编辑分类" },
            primaryEnabled: { controller.chosenCategory != nil }, actions: {
                var result: [LauncherAction] = [
                    .init(id: "focus-create", title: "创建专注分类", icon: "plus", shortcut: .init("n", modifiers: .command), group: 1, perform: { showCategory(nil) })
                ]
                if let category = controller.chosenCategory {
                    result += [
                        .init(id: "focus-edit-category", title: controller.isCustomCategory ? "编辑专注分类" : "复制并编辑分类", icon: "pencil", perform: { showCategory(category) }),
                        .init(id: "focus-copy-websites", title: "复制网站", icon: "link", shortcut: .init("c", modifiers: [.command, .option]), group: 2, perform: { UtilityActions.copy(category.websites.joined(separator: "\n"), feedback: "已复制网站") }),
                        .init(id: "focus-copy-apps", title: "复制应用", icon: "app", shortcut: .init("c", modifiers: [.command, .control]), group: 2, perform: { UtilityActions.copy(category.applications.map(\.id).joined(separator: "\n"), feedback: "已复制应用") }),
                        .init(id: "focus-export", title: "导出分类", icon: "square.and.arrow.down", group: 3, perform: controller.exportCategory)
                    ]
                    if controller.isCustomCategory { result.append(.init(id: "focus-delete", title: "删除专注分类", icon: "trash", shortcut: .init("x", modifiers: .control), group: 4, destructive: true, perform: controller.deleteCategory)) }
                }
                return result
            }, updates: updates, enter: { query in controller.categoryQuery = query; controller.selectedCategory = controller.visibleCategories.first?.id; return nil }, actionShortcutsEnabled: true
        )
        let importer = LauncherPage(id: importPage, placeholder: "", badge: ("导入专注分类", "target"), contentPlacement: .underChrome,
                                   content: { AnyView(FocusImportView(controller: controller)) }, back: back, submit: controller.importCategories,
                                   returnBindings: .init(primary: .plain), primaryTitle: { "选择文件" }, headerInput: .none)
        let anchor = SettingsItem(id: settingsID, page: settingsID, title: "专注", keywords: "Focus 屏蔽 允许 应用 网站 会话 分类 暂停 恢复 临时放行 系统专注 过滤条件 联动")
        let settings = LauncherSettingsPage(id: settingsID, title: "Keylane Focus", symbol: "target", subtitle: "管理专注会话与分类。", order: 144,
                                            items: [anchor], titlebar: controller.permission.titlebar("启用专注"), centeredHeader: true,
                                            content: { [weak model] in
            guard let model else { return AnyView(EmptyView()) }
            return AnyView(FocusSettings(model: model, controller: controller, commands: commands).settingsAnchor(anchor))
        })
        return LauncherModule(id: .init(rawValue: settingsID), title: "专注", symbol: "target", commands: commands,
                              pages: [categoryEditor, sessionEditor, search, importer], settings: [settings],
                              services: [.init(start: controller.startService, stop: controller.stopService)],
                              searchUpdates: [updates, controller.permission.updates])
    }
}
private struct FocusSettings: View {
    @ObservedObject var model: Model
    @ObservedObject var controller: FocusController
    let commands: [LauncherModule.Command]
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup {
                SettingsRow("临时放行时长", detail: "被屏蔽的应用与网站可以临时使用多久。") {
                    Picker("临时放行时长", selection: $controller.preferences.snoozeMinutes) {
                        Text("不允许临时放行 系统专注 过滤条件 联动").tag(0)
                        ForEach([1, 3, 5, 10], id: \.self) { Text("\($0) 分钟").tag($0) }
                    }.labelsHidden().frame(width: 150)
                }
                SettingsRow("允许所有网站", detail: "允许浏览器且未列出特定网站时，允许访问所有网站。") {
                    Toggle("允许所有网站", isOn: $controller.preferences.allowAllWebsites).labelsHidden()
                }
                SettingsRow("恢复已退出的应用", detail: "会话结束时，重新打开专注功能退出的应用。") {
                    Toggle("恢复已退出的应用", isOn: $controller.preferences.restoreApplications).labelsHidden()
                }
                SettingsRow("播放声音", detail: "为专注通知播放声音。") {
                    Toggle("播放声音", isOn: $controller.preferences.playSound).labelsHidden()
                }
            }
            SettingsGroup {
                SettingsRow("系统专注模式联动", detail: "在系统设置 → 专注模式 → 添加过滤条件中选择 Keylane，并配置分类。系统只启动和结束自动会话，保留手动会话；Keylane 需保持运行。") {
                    Button("打开系统设置") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")!)
                    }
                }
                if controller.systemManaged {
                    SettingsRow("正在跟随系统专注模式", detail: controller.session?.configuration.goal ?? "") { EmptyView() }
                }
                FocusMessage(text: controller.message)
            }
            ExtensionCommandPreferences(model: model, commands: commands)
        }
    }
}
