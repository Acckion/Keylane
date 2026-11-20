import AppKit
import Combine
import KeylaneCore
import SwiftUI

enum ThemeModule {
    static let settingsItem = SettingsItem(id: "themes", page: "general", title: "主题与 Theme Studio", keywords: "Theme Studio 背景 渐变 颜色 导入 分享 深色 浅色")
    static let pageID = PageID(rawValue: "SwitchTheme")
    static func make(model: Model) -> LauncherModule {
        let switcher = ThemeSwitcher(store: model.themeStore)
        let apply = { [weak model] in
            guard let model, let value = switcher.selected else { return }
            do {
                try model.themeStore.assign(value.id)
                model.appearance = value.appearance.rawValue
                (NSApp.delegate as? Delegate)?.hideLauncher()
            } catch { (NSApp.delegate as? Delegate)?.showLauncherFeedback(error.localizedDescription, style: .failure) }
        }
        return .init(id: .init(rawValue: "keylane.themes"), origin: .application, title: "主题", symbol: "paintpalette",
                     commands: [
                        .init(declaration: .init(id: .init(rawValue: "theme-studio"), title: "Theme Studio", detail: "创建、编辑和分享 Keylane 主题", symbol: "paintpalette", keywords: ["主题工作室", "主题", "外观", "Theme Studio"], settingsPage: "general"), execute: { [weak model] _ in
                            (NSApp.delegate as? Delegate)?.hideLauncher(); model?.themeStudio.show()
                        }),
                        .init(declaration: .init(id: .init(rawValue: "switch-theme"), title: "切换主题", detail: "预览并应用已保存的主题", symbol: "circle.lefthalf.filled", keywords: ["Switch Theme", "深色", "浅色", "外观"], destination: .page(pageID), settingsPage: "general"))
                     ], pages: [
                        .init(id: pageID, placeholder: "搜索主题…", badge: ("主题", "paintpalette"), contentPlacement: .underChrome,
                              content: { AnyView(ThemeSwitcherView(switcher: switcher)) }, queryChanged: { switcher.query = $0; switcher.reconcile() },
                              move: switcher.move, submit: apply, primaryTitle: { "应用主题" }, primaryEnabled: { switcher.selected != nil },
                              actions: { [weak model] in [
                                .init(id: "apply-theme", title: "应用主题", icon: "checkmark", shortcut: .init(.return, modifiers: []), perform: apply),
                                .init(id: "open-theme-studio", title: "在 Theme Studio 中打开", icon: "paintpalette") {
                                    guard let model else { return }
                                    if let theme = switcher.selected { model.themeStudio.select(theme.id) }
                                    (NSApp.delegate as? Delegate)?.hideLauncher(); model.themeStudio.show()
                                }
                              ] }, updates: switcher.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                              enter: { query in switcher.query = query; switcher.reconcile(); return query })
                     ])
    }
}

final class ThemeSwitcher: ObservableObject {
    let store: ThemeStore
    @Published var query = ""
    @Published var selectedID: UUID?
    private var changes: AnyCancellable?
    init(store: ThemeStore) {
        self.store = store
        changes = store.$library.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reconcile(); self?.objectWillChange.send() }
    }
    var matches: [ThemeDefinition] { store.library.all.filter { query.isEmpty || $0.name.localizedStandardContains(query) } }
    var selected: ThemeDefinition? { matches.first { $0.id == selectedID } }
    func reconcile() { if selected == nil { selectedID = matches.first?.id } }
    func move(_ delta: Int) {
        let values = matches
        guard !values.isEmpty else { return }
        let index = values.firstIndex { $0.id == selectedID } ?? 0
        selectedID = values[min(values.count - 1, max(0, index + delta))].id
    }
}
struct ThemeSwitcherView: View {
    @ObservedObject var switcher: ThemeSwitcher
    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(switcher.matches) { theme in
                            Button { switcher.selectedID = theme.id } label: {
                                ResultListRow(selected: switcher.selectedID == theme.id) {
                                    Circle().fill(theme.color(.selection).swiftUI).overlay { Image(systemName: theme.appearance == .dark ? "moon.fill" : "sun.max.fill").font(.caption).foregroundStyle(theme.color(.text).swiftUI) }
                                } content: { Text(theme.name).lineLimit(1) }
                            }.buttonStyle(.plain).id(theme.id)
                        }
                        if switcher.matches.isEmpty { Text("没有匹配的主题").foregroundStyle(.secondary).padding() }
                    }.padding(.horizontal, 10)
                }.onChange(of: switcher.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
            }.frame(width: 235)
            Divider()
            ScrollView {
                if let theme = switcher.selected { ThemePreview(theme: theme).padding(20) }
            }.frame(maxWidth: .infinity)
        }.padding(.top, VisualStyle.launcherTopInset).padding(.bottom, VisualStyle.launcherBottomInset)
    }
}
