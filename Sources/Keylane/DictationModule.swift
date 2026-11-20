import AppKit
import Combine
import KeylaneCore
import SwiftUI

enum DictationModule {
    static let historyPage = PageID(rawValue: "DictationHistory")
    static let stylePage = PageID(rawValue: "DictationStyleEditor")
    static let connectionItem = SettingsItem(id: "dictation-connection", page: "dictation", title: "云端听写",
                                              keywords: "Dictation 语音 转写 麦克风 录音 OpenAI ElevenLabs API")
    static let behaviorItem = SettingsItem(id: "dictation-behavior", page: "dictation", title: "听写录音与输出",
                                            keywords: "按住说话 粘贴 复制 自动提交 语言 快捷键")
    static let personalizationItem = SettingsItem(id: "dictation-personalization", page: "dictation-personalization", title: "个性化与词汇",
                                                   keywords: "听写 指令 术语 人名 应用上下文 vocabulary")
    static let stylesItem = SettingsItem(id: "dictation-styles", page: "dictation-styles", title: "听写样式",
                                          keywords: "Style 邮件 消息 应用 网站 自动样式")
    static let statisticsItem = SettingsItem(id: "dictation-statistics", page: "dictation-statistics", title: "听写统计",
                                              keywords: "听写 字数 速度 节省时间 历史")

    static func make(model: Model) -> LauncherModule {
        let controller = model.dictation
        let settings = controller.settings
        let draft = DictationStyleDraft()
        let edit: (DictationStyle?) -> Void = { [weak model] value in
            draft.prepare(value); model?.openPage(stylePage, origin: .menu)
        }
        controller.canRun = { [weak model] in
            model?.launcherModules?.isCommandModuleEnabled(.init(rawValue: "dictate")) == true
        }
        controller.canPaste = { [weak model] in model?.crossAppPaste.available == true }
        controller.commandShortcutAssigned = { [weak model] in model?.bindings["dictate"] != nil }
        controller.invokeDefaultShortcut = { [weak model] in model?.runCommand(.init(rawValue: "dictate"), origin: .shortcut) }
        controller.previousApplication = { (NSApp.delegate as? Delegate)?.previousApplication }
        controller.openSettings = { [weak model] in model?.openSettings(page: "dictation") }
        controller.hideLauncher = { (NSApp.delegate as? Delegate)?.hideLauncher() }
        controller.feedback = { message, style in (NSApp.delegate as? Delegate)?.showLauncherFeedback(message, style: style) }
        controller.deliverNote = { [weak model, weak controller] text in
            guard model?.runCommand(.init(rawValue: "create-apple-note"), origin: .menu, arguments: [text]) == true else {
                _ = DictationDelivery.copy(text)
                controller?.feedback("听写已保存并复制。请先启用 Apple 备忘录，再创建笔记。", .failure)
                return
            }
        }
        var commands: [LauncherModule.Command] = []
        for (id, title, detail, target) in [
            ("dictate", "开始听写", "在当前应用中口述输入，再按一次结束", DictationController.Destination.application),
            ("dictate-to-note", "口述创建备忘录", "口述后打开预填正文的备忘录编辑器", .note),
            ("dictate-to-ai", "口述提问", "将口述内容交给 Quick AI 或 AI Chat", .ai)
        ] {
            commands.append(.init(declaration: .init(id: .init(rawValue: id), title: title, detail: detail, symbol: "mic",
                                                     keywords: ["Dictation", "dictate", "听写", "语音输入", "口述"], settingsPage: "dictation"),
                                  execute: { _ in controller.toggle(target) }))
        }
        commands += [
            .init(declaration: .init(id: .init(rawValue: "dictation-history"), title: "听写历史", detail: "查找、复制、粘贴或重试本机转写",
                                     symbol: "clock.arrow.circlepath", keywords: ["Dictation History", "转写记录", "录音"],
                                     destination: .page(historyPage), settingsPage: "dictation")),
            .init(declaration: .init(id: .init(rawValue: "dictation-last"), title: "获取最近听写", detail: "复制最近一次成功的听写",
                                     symbol: "doc.on.clipboard", keywords: ["Get Last Transcription", "最近转写"], settingsPage: "dictation"), execute: { _ in
                controller.loadLastTranscription()
            }),
            .init(declaration: .init(id: .init(rawValue: "create-dictation-style"), title: "创建听写样式", detail: "为应用和网站定制语气与格式",
                                     symbol: "text.badge.plus", keywords: ["Create Style", "听写格式"], settingsPage: "dictation-styles"), execute: { _ in edit(nil) }),
            .init(declaration: .init(id: .init(rawValue: "add-dictation-word"), title: "添加听写词汇", detail: "添加输入或所选的专用词汇",
                                     symbol: "text.badge.plus", keywords: ["Add Word to Vocabulary", "术语", "人名"], settingsPage: "dictation-personalization"),
                  arguments: .init(count: 0...1) { _, arguments in
                let app = NSWorkspace.shared.frontmostApplication
                let original = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? controller.previousApplication() : app
                let position = original.flatMap(SnippetTextTarget.position)
                let selection = position.map { ($0.text as NSString).substring(with: NSRange(location: $0.range.location, length: $0.range.length)) }
                let term = (arguments.first ?? selection ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !term.isEmpty, term.count <= 20, term.rangeOfCharacter(from: .controlCharacters) == nil,
                      settings.options.validVocabulary.count < 50 else {
                    controller.feedback("请提供 1–20 个字符的词汇，最多保存 50 项。", .failure); return
                }
                if !settings.options.vocabulary.contains(term) { settings.options.vocabulary.append(term) }
                controller.feedback("已添加听写词汇", .success)
            })
        ]
        let pages = [
            LauncherPage(id: historyPage, placeholder: "搜索听写历史…", badge: ("听写历史", "mic"), contentPlacement: .underChrome,
                         content: { AnyView(DictationHistoryView(controller: controller)) }, queryChanged: { query in
                             controller.historyQuery = query; controller.selectedID = controller.matches.first?.id
                         }, move: controller.move,
                         submit: { controller.use(controller.selected, copyOnly: false) },
                         primaryTitle: { "粘贴听写" }, primaryEnabled: { controller.selected?.text.isEmpty == false && !controller.busy },
                         actions: {
                             guard let record = controller.selected else { return [] }
                             return [
                                 .init(id: "dictation-copy", title: "复制听写", icon: "doc.on.doc", shortcut: .init("c", modifiers: .command),
                                       enabled: !record.text.isEmpty) { controller.use(record, copyOnly: true) },
                                 .init(id: "dictation-paste", title: "粘贴听写", icon: "doc.on.clipboard", enabled: !record.text.isEmpty) { controller.use(record, copyOnly: false) },
                                 .init(id: "dictation-retry", title: record.error == nil ? "重新整理" : "重试听写", icon: "arrow.clockwise",
                                       group: 1, enabled: !controller.busy && (!record.rawText.isEmpty || record.hasRecording)) { controller.retry(record) },
                                 .init(id: "dictation-remove", title: "删除听写", icon: "trash", group: 2, destructive: true) { controller.requestedDeletion = record.id },
                                 .init(id: "dictation-clear", title: "清空所有听写历史…", icon: "trash", group: 2, destructive: true) { controller.requestsClearHistory = true },
                                 .init(id: "dictation-settings", title: "听写设置…", icon: "gearshape", group: 3) { controller.openSettings() }
                             ]
                         }, updates: controller.updates, enter: { query in controller.historyQuery = query; controller.loadHistory(); return query }),
            LauncherPage(id: stylePage, placeholder: "", badge: ("听写样式", "textformat"), contentPlacement: .form,
                         content: { AnyView(DictationStyleEditor(draft: draft)) }, submit: { [weak model] in
                             guard draft.canSave else { return }; draft.save(to: settings); model?.goBackInLauncher()
                         }, returnBindings: .init(primary: .command), primaryTitle: { "保存样式" }, primaryEnabled: { draft.canSave },
                         updates: draft.objectWillChange.map { _ in () }.eraseToAnyPublisher())
        ]
        let settingsPages: [LauncherSettingsPage] = [
            .init(id: "dictation", title: "听写", symbol: "mic", subtitle: "在任何应用中口述输入，由云端模型转写与整理。", order: 10,
                  items: [connectionItem, behaviorItem], titlebar: settings.permission.titlebar("启用听写"),
                  centeredHeader: true, content: { [weak model] in
                      guard let model else { return AnyView(EmptyView()) }
                      return AnyView(DictationPreferences(model: model, controller: controller, settings: settings, configuration: model.aiSettings, commands: commands))
                  }),
            .init(id: personalizationItem.page, title: personalizationItem.title, symbol: "person.text.rectangle", subtitle: "设置全局规则、术语与应用上下文。", order: 10,
                  items: [personalizationItem], parentID: "dictation", content: { AnyView(DictationPersonalization(settings: settings)) }),
            .init(id: stylesItem.page, title: stylesItem.title, symbol: "textformat", subtitle: "按应用与网站匹配听写风格。", order: 10,
                  items: [stylesItem], parentID: "dictation", trailingToolbar: { AnyView(Button("创建样式", systemImage: "plus") { edit(nil) }) },
                  content: { AnyView(DictationStylesPreferences(settings: settings, edit: edit)) }),
            .init(id: statisticsItem.page, title: statisticsItem.title, symbol: "chart.bar", subtitle: "根据本机听写历史计算，不发送统计遥测。", order: 10,
                  items: [statisticsItem], parentID: "dictation", content: { AnyView(DictationStatisticsView(controller: controller)) })
        ]
        return LauncherModule(id: .init(rawValue: "keylane.dictation"), title: "听写", symbol: "mic", commands: commands, pages: pages,
                              settings: settingsPages, services: [.init(start: controller.startService, stop: controller.stopService)],
                              searchUpdates: [settings.permission.updates])
    }
}

struct DictationHistoryView: View {
    @ObservedObject var controller: DictationController
    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        if controller.matches.isEmpty {
                            Text("还没有听写记录").foregroundStyle(.secondary).padding(24)
                        }
                        ForEach(controller.matches) { record in
                            Button { controller.selectedID = record.id } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: record.error == nil ? "text.quote" : "exclamationmark.circle")
                                        .foregroundStyle(record.error == nil ? Color.secondary : .orange).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(record.text.isEmpty ? "转写未完成" : record.text).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                        Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(12).frame(maxWidth: .infinity)
                                    .background(controller.selectedID == record.id ? Color.primary.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).id(record.id)
                        }
                    }.padding(.horizontal, 12)
                }.launcherScrollInsets().launcherScrollEdgeFade()
                    .onChange(of: controller.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
            }.frame(maxWidth: .infinity)
            Divider()
            ScrollView {
                if let record = controller.selected {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(record.text.isEmpty ? record.rawText : record.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                        LabeledContent("应用", value: record.application.isEmpty ? "—" : record.application)
                        LabeledContent("时间", value: record.date.formatted())
                        LabeledContent("录音时长", value: "\(Int(record.duration)) 秒")
                        if let style = record.styleName { LabeledContent("样式", value: style) }
                        if record.hasRecording { Text("已在本机保留录音，可重试。").font(.caption).foregroundStyle(.secondary) }
                        if record.rawText != record.text, !record.rawText.isEmpty {
                            DisclosureGroup("原始转写") { Text(record.rawText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                        if let error = record.error { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange) }
                    }.padding(22)
                }
            }.launcherScrollInsets().launcherScrollEdgeFade().frame(maxWidth: .infinity)
        }
        .confirmationDialog("删除这条听写及对应录音？", isPresented: Binding(get: { controller.requestedDeletion != nil }, set: { if !$0 { controller.requestedDeletion = nil } })) {
            Button("删除", role: .destructive) { if let id = controller.requestedDeletion { controller.remove(id) }; controller.requestedDeletion = nil }
        }
        .confirmationDialog("清空所有听写历史及对应录音？", isPresented: $controller.requestsClearHistory, titleVisibility: .visible) {
            Button("清空所有听写", role: .destructive) { controller.removeAll() }
        }
    }
}
