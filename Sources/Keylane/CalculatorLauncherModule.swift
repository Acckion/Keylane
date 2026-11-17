import AppKit
import Combine
import KeylaneCore
import SwiftUI

enum CalculatorLauncherModule {
    static let resultID = CommandID(rawValue: "calculator")
    static let colorDetail = "颜色换算"
    fileprivate static let settingsItem = SettingsItem(id: "calculator-options", page: "keylane.calculator", title: "计算器",
                                                       keywords: "calculator 颜色 语法 rem em px")
    private static let historyPage = PageID(rawValue: "CalculatorHistory")
    fileprivate static let historyID = CommandID(rawValue: "calculator-history")
    fileprivate static let historyTitle = "计算器历史"
    fileprivate static let historySettingsItem = SettingsItem(id: "calculator-history-command", page: "keylane.calculator",
                                                              title: historyTitle, keywords: "calculator history 计算记录 别名 快捷键")
    fileprivate static let defaultPixelsPerEm = 16.0
    fileprivate static let pixelsRange = 1.0...512.0
    private static var pixelsPerEm: Double {
        let value = UserDefaults.standard.double(forKey: "calculatorPixelsPerEm")
        return pixelsRange.contains(value) ? value : defaultPixelsPerEm
    }

    static func make(model: Model) -> LauncherModule {
        let exchange = CalculatorExchangeRates()
        let history = CalculatorHistory()
        let defaults = UserDefaults.standard
        var pageObservation: AnyCancellable?
        func result(_ query: String) -> (value: String?, detail: String)? {
            if (defaults.object(forKey: "calculatorColorConversion") as? Bool ?? true),
               let color = CalculatorColor(query) {
                return (color.hexLabel, colorDetail)
            }
            let conversion = CalculatorConversion(query)
            if let value = conversion?.unitResult { return (value, "单位换算") }
            if let value = CalculatorLanguage.evaluate(query, pixelsPerEm: pixelsPerEm) { return (value, "回车复制结果") }
            if let conversion {
                return exchange.result(conversion) ?? (nil, "单位不支持或无法互相换算")
            }
            return nil
        }
        let provider = LauncherModule.Provider(namespace: .exact(resultID), entries: { input in
            guard let result = result(input.query), let value = result.value else { return [] }
            return [Entry(id: resultID.rawValue, commandID: resultID, name: value, detail: result.detail,
                          symbol: "equal", rankingKind: .calculator)]
        }, resolve: { [weak model] id, origin in
            guard id == resultID, origin != .shortcut, let query = model?.query,
                  let value = result(query)?.value else { return nil }
            return { copy(value, expression: query, history: history) }
        }, primaryTitle: { $0.detail == colorDetail ? "复制颜色为…" : "复制结果" }, actions: { [weak model] row in
            guard let query = model?.query else { return [] }
            if row.detail == colorDetail, let color = CalculatorColor(query) {
                return color.formats.map { format in
                    LauncherAction(id: "copy-color-" + format.title, title: "复制 " + format.title, icon: "doc.on.doc") {
                        copy(format.text, expression: query, history: history, answer: row.name)
                    }
                }
            }
            return actions(query: query, value: row.name, model: model, history: history, exchange: exchange)
        })
        let hintID = CommandID(rawValue: "calculator-hint")
        let hint = LauncherModule.Provider(namespace: .exact(hintID), entries: { input in
            let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
            let outcome = result(query)
            guard outcome?.value == nil,
                  outcome != nil || query.folding(options: .widthInsensitive, locale: .current).hasPrefix("=") else { return [] }
            let message = outcome?.detail ?? (query.count == 1 ? "例如 2 × (3 + 4)、5 km to mi、100 美元转人民币" : "表达式不完整或无法计算")
            return [Entry(id: hintID.rawValue, commandID: hintID, name: message,
                          detail: "计算器", symbol: "equal", rankingKind: .calculator)]
        }, resolve: { _, _ in nil })
        let settingsID = "keylane.calculator"
        let help = LauncherModule.Command(declaration: .init(id: .init(rawValue: "calculator-help"), title: "计算器",
                                                            detail: "在搜索框输入表达式", symbol: "equal.circle",
                                                            keywords: ["Calculator", "计算"], destination: .action)) { [weak model] _ in
            model?.query = "="
        }
        let showHistory = LauncherModule.Command(declaration: .init(id: historyID, title: historyTitle,
                                                                   detail: "搜索最近三个月的计算", symbol: "clock.arrow.circlepath",
                                                                   keywords: ["Calculator History", "计算记录"], destination: .page(historyPage)))
        let settings = LauncherSettingsPage(id: settingsID, title: "计算器", symbol: "equal.circle",
                                            subtitle: "在主搜索中计算数字和表达式。", order: 128,
                                            items: [settingsItem, historySettingsItem], centeredHeader: true) { [weak model] in
            guard let model else { return AnyView(EmptyView()) }
            return AnyView(CalculatorPreferences(model: model))
        }
        var module = LauncherModule(id: .init(rawValue: settingsID), commands: [help, showHistory],
                                    providers: [provider, hint], pages: [history.page(id: historyPage)],
                                    settings: [settings], services: [.init(start: { [weak model] in
            pageObservation = model?.$pageID.dropFirst().sink { [weak model] next in
                guard let model, model.pageID == .root, next != .root,
                      let answer = result(model.query)?.value else { return }
                history.record(expression: model.query, answer: answer)
            }
        }, stop: {
            pageObservation?.cancel()
            pageObservation = nil
            exchange.stop()
        })],
                                    searchUpdates: [exchange.updates,
                                                    NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                                                        .map { _ in SettingsValues(defaults: defaults) }.removeDuplicates().map { _ in () }.eraseToAnyPublisher()])
        module.launcherShown = exchange.startPresenting
        module.launcherHidden = { [weak model] in
            exchange.endPresentation()
            guard let model, model.pageID == .root, let value = result(model.query)?.value else { return }
            history.record(expression: model.query, answer: value)
        }
        return module
    }

    private struct SettingsValues: Equatable {
        let color: Bool
        let pixels: Double

        init(defaults: UserDefaults) {
            color = defaults.object(forKey: "calculatorColorConversion") as? Bool ?? true
            pixels = defaults.double(forKey: "calculatorPixelsPerEm")
        }
    }

    private static func actions(query: String, value: String, model: Model?, history: CalculatorHistory,
                                exchange: CalculatorExchangeRates) -> [LauncherAction] {
        var actions: [LauncherAction] = [
            .init(id: "calculator-copy", title: "复制结果", icon: "doc.on.doc", keys: ["↩"]) {
                copy(value, expression: query, history: history)
            },
            .init(id: "calculator-paste", title: "粘贴结果", icon: "clipboard", keys: ["⌘", "↩"]) {
                guard UtilityActions.copy(value), let delegate = NSApp.delegate as? Delegate else { return }
                history.record(expression: query, answer: value)
                delegate.pasteIntoPreviousApplication(clipboardGeneration: NSPasteboard.general.changeCount)
            },
            .init(id: "calculator-copy-raw", title: "复制无格式结果", icon: "doc.on.doc", keys: ["⌥", "⌘", "C"]) {
                copy(unformatted(value), expression: query, history: history, answer: value)
            },
            .init(id: "calculator-copy-expression", title: "复制算式和结果", icon: "doc.on.doc", keys: ["⌥", "⇧", "⌘", "C"]) {
                copy(query + " = " + value, expression: query, history: history, answer: value)
            },
            .init(id: "calculator-answer-search", title: "将结果放入搜索框", icon: "magnifyingglass", group: 1) { [weak model] in
                history.record(expression: query, answer: value)
                model?.query = value
            },
            .init(id: "calculator-history-menu", title: "显示计算历史", icon: "clock.arrow.circlepath", group: 1) { [weak model] in
                history.record(expression: query, answer: value)
                model?.openPage(historyPage, origin: .search)
            }
        ]
        if let conversion = CalculatorConversion(query) {
            actions.append(.init(id: "calculator-swap", title: "交换换算单位", icon: "arrow.left.arrow.right", group: 1) { [weak model] in
                model?.query = Calculator.format(conversion.amount) + " " + conversion.target + " in " + conversion.source
            })
            if conversion.currencies != nil {
                actions.append(.init(id: "calculator-refresh-rates", title: "刷新汇率", icon: "arrow.clockwise", group: 1) {
                    exchange.refresh()
                })
            }
        }
        return actions
    }

    private static func unformatted(_ value: String) -> String {
        let locale = Locale.current
        if let number = Calculator.evaluate(value, locale: locale) {
            return Calculator.format(number, locale: Locale(identifier: "en_US_POSIX"))
        }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        if let number = formatter.number(from: value)?.doubleValue {
            return Calculator.format(number, locale: Locale(identifier: "en_US_POSIX"))
        }
        return value
    }

    private static func copy(_ value: String, expression: String, history: CalculatorHistory, answer: String? = nil) {
        history.record(expression: expression, answer: answer ?? value)
        UtilityActions.copy(value, feedback: "已复制计算结果")
    }
}

private struct CalculatorPreferences: View {
    @ObservedObject var model: Model
    @AppStorage("calculatorSyntaxHighlighting") private var syntax = true
    @AppStorage("calculatorColorConversion") private var color = true
    @AppStorage("calculatorPixelsPerEm") private var pixels = CalculatorLauncherModule.defaultPixelsPerEm

    private var pixelValue: Binding<Double> {
        let range = CalculatorLauncherModule.pixelsRange
        return Binding(get: {
            range.contains(pixels) ? pixels : CalculatorLauncherModule.defaultPixelsPerEm
        }, set: { value in
            guard value.isFinite else { return }
            pixels = min(max(value, range.lowerBound), range.upperBound)
        })
    }

    var body: some View {
        SettingsPageSections {
            SettingsGroup {
                Toggle(isOn: $syntax) {
                    SettingsRowLabel(title: "语法高亮", detail: nil)
                }
                Divider()
                Toggle(isOn: $color) {
                    SettingsRowLabel(title: "颜色换算", detail: "在主搜索中预览颜色并转换颜色格式。")
                }
                Divider()
                SettingsRow("REM / EM 转像素", detail: "设置 1 rem 或 1 em 对应的像素数。") {
                    HStack(spacing: 4) {
                        TextField("每 REM / EM 的像素数", value: pixelValue, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 66)
                        Stepper("调整像素数", value: pixelValue, in: CalculatorLauncherModule.pixelsRange)
                            .labelsHidden()
                    }
                }
            }.settingsAnchor(CalculatorLauncherModule.settingsItem)

            SettingsSectionTitle(title: "命令")
            CommandSettingsList(items: [CalculatorLauncherModule.historyID], id: \.self) { id in
                CommandSettingsEntry(title: CalculatorLauncherModule.historyTitle, model: model, commandID: id,
                                     isEnabled: Binding(get: { !model.disabledCommands.contains(id.rawValue) }, set: {
                    if $0 { model.disabledCommands.remove(id.rawValue) }
                    else { model.disabledCommands.insert(id.rawValue) }
                })) {
                    SettingsIcon(symbol: "equal.circle", artwork: ModuleArtwork.settings("keylane.calculator"))
                }
            }.settingsAnchor(CalculatorLauncherModule.historySettingsItem)
        }
    }
}
