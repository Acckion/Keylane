import AppKit
import KeylaneCore
import SwiftUI

struct TranslatorLanguagePicker: View {
    let value: String
    let title: String
    var allowsDetection = false
    let navigation: String
    @Binding var open: Bool
    let select: (String) -> Void
    @State private var query = ""

    var body: some View {
        Button {
            query = ""
            open.toggle()
        } label: {
            HStack(spacing: 7) {
                Text(title).lineLimit(1)
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(allowsDetection ? "源语言" : "目标语言")
        .accessibilityValue(title)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            let languages = (allowsDetection ? [TranslationLanguage.detect] : []) + TranslationLanguage.all
            let options = languages.map { ResultFilterOption(id: $0.id, title: $0.title, symbol: $0.id == "auto" ? "wand.and.stars" : "character",
                                                             keywords: [$0.english, $0.chinese, $0.id]) }
            ResultFilterPanel(selection: value, options: ResultFilterPanel.matches(options, query: query), query: $query,
                              searchPlaceholder: "搜索语言…", navigation: navigation, width: 260, maximumVisibleRows: 7,
                              choose: { select($0.id); open = false }, dismiss: { open = false })
        }
    }
}

struct TranslatorView: View {
    @ObservedObject var controller: TranslatorController
    let back: () -> Void
    var navigation = "arrows"
    @Environment(\.conversationInputEnabled) private var inputEnabled
    @Environment(\.conversationInputFocusToken) private var focusToken

    var body: some View {
        GeometryReader { geometry in
            let inset = VisualStyle.launcherEdgeInset
            let columnWidth = max(0, geometry.size.width / 2 - inset)
            let contentHeight = max(0, geometry.size.height - inset - VisualStyle.launcherBottomInset)
            HStack(spacing: 0) {
                sourceColumn
                    .frame(width: columnWidth, height: contentHeight)
                    .background {
                        Color.primary.opacity(0.035)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .mask {
                                Rectangle().overlay(alignment: .trailing) {
                                    Circle().frame(width: 48, height: 48)
                                        .offset(x: 24)
                                        .blendMode(.destinationOut)
                                }.compositingGroup()
                            }
                    }
                targetColumn.frame(width: columnWidth, height: contentHeight)
            }
            .padding(.leading, inset)
            .padding(.top, inset)
            LauncherBackButton(action: back)
                .padding(inset)
            Button(action: controller.swap) {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 15, weight: .medium))
                    .frame(width: VisualStyle.launcherControlDiameter, height: VisualStyle.launcherControlDiameter)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(!controller.canUseOutput)
            .help("交换语言（⌘S）")
            .accessibilityLabel("交换语言")
            .position(x: geometry.size.width / 2, y: inset + contentHeight / 2)
        }
    }

    private var sourceColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer(minLength: 48)
                TranslatorLanguagePicker(value: controller.source, title: controller.sourceTitle,
                                         allowsDetection: true, navigation: navigation, open: sourceMenu) {
                    controller.selectLanguage($0, isSource: true)
                }
                Spacer(minLength: 48)
            }
            .frame(height: 42)
            TranslatorInput(text: $controller.input, enabled: inputEnabled && controller.languageMenu == nil, focusToken: focusToken, escape: {
                if !controller.input.isEmpty { controller.speech.stop(); controller.input = "" } else { back() }
            })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if controller.input.isEmpty {
                        Text("输入要翻译的文字…").font(.system(size: 23)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 13).padding(.top, 8).allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 12)
            HStack(spacing: 13) {
                SpeechControls(controller: controller)
                Spacer(minLength: 0)
                Text("\(controller.wordCount) 词 · \(controller.input.count) 字符")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 19).padding(.bottom, 15)
        }
    }

    private var targetColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                TranslatorLanguagePicker(value: controller.target,
                                         title: TranslationLanguage.language(controller.target)?.title ?? controller.target,
                                         navigation: navigation, open: targetMenu) {
                    controller.selectLanguage($0, isSource: false)
                }
                Spacer()
            }.frame(height: 42)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if controller.loading && controller.output.isEmpty {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(controller.output).font(.system(size: 23)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !controller.error.isEmpty {
                        Text(controller.error).font(VisualStyle.rowText).foregroundStyle(.secondary)
                        Button("重试", action: controller.retry).buttonStyle(ContentActionButtonStyle())
                    }
                }.padding(.horizontal, 24).padding(.top, 6)
            }
            HStack {
                Button {
                    controller.speech.speak(controller.output, language: controller.target)
                } label: { Image(systemName: "speaker.wave.2").frame(width: 24, height: 24) }
                .buttonStyle(.plain).disabled(!controller.canUseOutput).help("朗读译文").accessibilityLabel("朗读译文")
                Spacer()
            }.padding(.horizontal, 24).padding(.bottom, 15)
        }
    }

    private var sourceMenu: Binding<Bool> {
        Binding(get: { controller.languageMenu == "source" }, set: { open in
            if open { controller.languageMenu = "source" }
            else if controller.languageMenu == "source" { controller.languageMenu = nil }
        })
    }
    private var targetMenu: Binding<Bool> {
        Binding(get: { controller.languageMenu == "target" }, set: { open in
            if open { controller.languageMenu = "target" }
            else if controller.languageMenu == "target" { controller.languageMenu = nil }
        })
    }
}

private struct SpeechControls: View {
    let controller: TranslatorController
    @ObservedObject private var speech: TranslatorSpeech
    init(controller: TranslatorController) {
        self.controller = controller
        speech = controller.speech
    }
    var body: some View {
        HStack(spacing: 13) {
            Button {
                let prefix = controller.input.isEmpty ? "" : controller.input + " "
                speech.toggle(language: controller.source) { controller.input = prefix + $0 }
            } label: { Image(systemName: speech.recording ? "stop.circle.fill" : "mic").frame(width: 24, height: 24) }
            .foregroundStyle(speech.recording ? Color.accentColor : Color.primary)
            .help(speech.recording ? "停止语音输入" : "语音输入")
            .accessibilityLabel(speech.recording ? "停止语音输入" : "语音输入")
            Button {
                speech.speak(controller.input, language: controller.detectedSource ?? controller.source)
            } label: { Image(systemName: "speaker.wave.2").frame(width: 24, height: 24) }
            .disabled(controller.input.isEmpty).help("朗读原文").accessibilityLabel("朗读原文")
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(get: { !speech.error.isEmpty }, set: { _ in speech.dismissError() })) {
            Text(speech.error).font(VisualStyle.rowText).padding(16).frame(width: 280)
        }
    }
}

/// Keep IME composition local until the user commits the marked text.
private struct TranslatorInput: NSViewRepresentable {
    @Binding var text: String
    let enabled: Bool
    let focusToken: Int
    let escape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isRichText = false
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.font = .systemFont(ofSize: 23)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.setAccessibilityLabel("翻译原文")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if !view.hasMarkedText(), view.string != text { view.string = text }
        view.isEditable = enabled
        view.textColor = .labelColor
        if enabled, context.coordinator.focusToken != focusToken || !context.coordinator.wasEnabled {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async {
                guard context.coordinator.parent.enabled else { return }
                view.window?.makeFirstResponder(view)
            }
        }
        context.coordinator.wasEnabled = enabled
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TranslatorInput
        var focusToken: Int?
        var wasEnabled = false
        init(_ parent: TranslatorInput) { self.parent = parent }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText() else { return false }
            parent.escape()
            return true
        }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, !view.hasMarkedText() else { return }
            parent.text = view.string
        }
    }
}
