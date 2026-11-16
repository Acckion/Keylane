import AppKit
import KeylaneCore
import SwiftUI

struct SnippetEditor: View {
    @ObservedObject var controller: SnippetsController
    let back: () -> Void
    @StateObject private var editor = SnippetEditorState()
    @FocusState private var focus: Field?
    @State private var tagText = ""

    private enum Field: Hashable { case title, keyword, tags }
    private static let symbols = ["text.alignleft", "terminal", "text.quote", "envelope", "calendar", "star",
                                  "code", "link", "heart", "book", "person", "checkmark.seal"]

    var body: some View {
        LauncherCreationForm(back: back) {
            Link("文字片段指南", destination: SnippetsModule.guideURL)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).underline()
        } fields: {
            HStack(alignment: .top, spacing: 22) {
                contentColumn.zIndex(1)
                VStack(alignment: .leading, spacing: 20) {
                    field("名称与图标", focus: .title) {
                        HStack(spacing: 10) {
                            TextField("片段名称", text: $controller.draft.title).focused($focus, equals: .title)
                            Divider().frame(height: 22)
                            Menu {
                                ForEach(Self.symbols, id: \.self) { symbol in
                                    Button { controller.draft.icon = symbol } label: {
                                        Label(symbol, systemImage: symbol)
                                    }
                                }
                            } label: {
                                Image(systemName: controller.draft.icon ?? "text.alignleft")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .accessibilityLabel("片段图标")
                        }
                    }
                    field("关键词", focus: .keyword) {
                        TextField("关键词", text: $controller.draft.keyword).focused($focus, equals: .keyword)
                    }
                    field("标签", focus: .tags) {
                        TextField("输入标签，以逗号分隔", text: $tagText)
                            .focused($focus, equals: .tags)
                            .onChange(of: tagText) { _, value in
                                controller.draft.tags = Snippet.normalizedTags(value.components(separatedBy: CharacterSet(charactersIn: ",，")))
                            }
                    }
                    if !controller.error.isEmpty {
                        Text(controller.error).font(.callout).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 650)
            .padding(.horizontal, 20)
        }
        .task(id: controller.draft.id) { tagText = controller.draft.tags.joined(separator: ", ") }
        .onExitCommand {
            if editor.completion != nil { editor.dismiss() }
            else { back() }
        }
    }

    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("片段")
            LauncherCreationControl(focused: editor.focused) {
                VStack(spacing: 4) {
                    SnippetRichTextView(draft: $controller.draft, state: editor)
                        .id(controller.draft.id)
                        .frame(height: 236)
                        .overlay(alignment: .topLeading) {
                            if controller.draft.text.isEmpty {
                                Text("输入片段内容…").foregroundStyle(.tertiary)
                                    .padding(.top, 4).padding(.leading, 1)
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                    toolbar
                }
            }
            .overlay(alignment: .topLeading) {
                if let menu = editor.completion {
                    GeometryReader { geometry in
                        completionMenu(menu)
                            .offset(x: min(max(10, menu.anchor.x + 12), max(10, geometry.size.width - 237)),
                                    y: max(12, menu.anchor.y + 10))
                    }
                }
            }
            HStack(spacing: 4) {
                Link("动态占位符", destination: URL(string: "https://manual.raycast.com/dynamic-placeholders")!)
                Text("可插入复制的文字或当前日期。").foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field<Content: View>(_ title: String, focus field: Field, @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            fieldLabel(title)
            LauncherCreationControl(focused: focus == field) {
                content().textFieldStyle(.plain).accessibilityLabel(title)
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
    }

    private var toolbar: some View {
        HStack(spacing: 9) {
            tool("粗体", "bold") { editor.formatFont(.boldFontMask) }
            tool("斜体", "italic") { editor.formatFont(.italicFontMask) }
            tool("下划线", "underline") { editor.toggleAttribute(.underlineStyle) }
            tool("删除线", "strikethrough") { editor.toggleAttribute(.strikethroughStyle) }
            tool("添加链接", "link") { editor.addLink() }
            Divider().frame(height: 21)
            tool("清除格式", "textformat.slash") { editor.clearFormatting() }
            Spacer()
            tool("插入动态占位符", "character.textbox") { editor.beginCompletion() }
        }
        .padding(.bottom, 2)
    }

    private func tool(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: icon, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .frame(width: 24, height: 26)
            .foregroundStyle(.secondary)
            .help(title)
    }

    private func completionMenu(_ menu: SnippetEditorState.Completion) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(menu.items) { item in
                        if item.kind == .date && menu.items.first?.kind != .date {
                            Divider().padding(.vertical, 4)
                            Text("日期与时间").font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                        }
                        LauncherMenuRow(title: item.title, symbol: item.symbol, selected: editor.highlighted == item.id,
                                        style: .filter, activate: { editor.insert(item) },
                                        highlight: { editor.highlighted = item.id }) { EmptyView() }
                        .id(item.id)
                    }
                }
                .padding(7)
            }
            .onChange(of: editor.highlighted) { _, item in
                if let item { proxy.scrollTo(item) }
            }
        }
        .frame(width: 224, height: min(292, CGFloat(menu.items.count * 42 + 14)))
        .modifier(LauncherMenuSurface(open: true))
    }
}

private struct SnippetPlaceholderOption: Identifiable {
    let kind: DynamicTemplate.Kind
    let title: String
    let symbol: String
    var example: String? = nil
    var id: String { kind.rawValue }
    var insertion: String { "{" + (example ?? kind.rawValue) + "}" }

    static let options: [Self] = [
        .init(kind: .calculator, title: "计算器", symbol: "plus.forwardslash.minus"),
        .init(kind: .uuid, title: "UUID", symbol: "touchid"),
        .init(kind: .clipboard, title: "剪贴板文字", symbol: "clipboard"),
        .init(kind: .argument, title: "参数", symbol: "character.textbox"),
        .init(kind: .cursor, title: "光标位置", symbol: "text.cursor"),
        .init(kind: .snippet, title: "引用片段", symbol: "text.alignleft", example: "snippet name=\"\""),
        .init(kind: .date, title: "日期", symbol: "calendar"),
        .init(kind: .time, title: "时间", symbol: "clock"),
        .init(kind: .datetime, title: "日期与时间", symbol: "calendar.badge.clock"),
        .init(kind: .day, title: "星期", symbol: "calendar.day.timeline.left")
    ]
}

private final class SnippetEditorState: ObservableObject {
    struct Completion {
        let range: NSRange
        let anchor: CGPoint
        let items: [SnippetPlaceholderOption]
    }

    static let baseFont = NSFont.systemFont(ofSize: 15)
    @Published var focused = false
    @Published private(set) var completion: Completion?
    @Published var highlighted: String?
    weak var view: SnippetNativeTextView?
    weak var scrollView: NSScrollView?
    private var dismissedRange: NSRange?

    func selectionChanged() {
        guard let view, let scrollView else { return }
        let selected = view.selectedRange()
        guard focused, selected.length == 0, !view.hasMarkedText(),
              let token = DynamicTemplate.completion(in: view.string, caret: selected.location),
              token.range != dismissedRange else {
            completion = nil
            if DynamicTemplate.completion(in: view.string, caret: selected.location)?.range != dismissedRange {
                dismissedRange = nil
            }
            return
        }
        let options = SnippetPlaceholderOption.options.filter { token.prefix.isEmpty || $0.id.hasPrefix(token.prefix.lowercased()) }
        guard !options.isEmpty else { completion = nil; return }
        let screen = view.firstRect(forCharacterRange: selected, actualRange: nil)
        guard !screen.isEmpty || screen.height > 0, let window = view.window else { completion = nil; return }
        let local = scrollView.convert(window.convertFromScreen(screen), from: nil)
        let point = CGPoint(x: local.minX, y: scrollView.isFlipped ? local.maxY : scrollView.bounds.height - local.minY)
        guard point.y > 0, point.y <= scrollView.bounds.height + 4 else { completion = nil; return }
        completion = Completion(range: token.range, anchor: point, items: options)
        if !options.contains(where: { $0.id == highlighted }) { highlighted = options.first?.id }
    }

    func dismiss() {
        dismissedRange = completion?.range
        completion = nil
    }

    func key(_ event: NSEvent) -> Bool {
        guard let completion, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        let index = completion.items.firstIndex { $0.id == highlighted } ?? 0
        switch event.keyCode {
        case 125, 126:
            highlighted = completion.items[NavigationBounds.move(index, by: event.keyCode == 125 ? 1 : -1,
                                                                   count: completion.items.count)].id
        case 36, 48, 76: insert(completion.items[index])
        case 53: dismiss()
        default: return false
        }
        return true
    }

    func insert(_ option: SnippetPlaceholderOption) {
        guard let view, let completion else { return }
        view.window?.makeFirstResponder(view)
        view.insertText(option.insertion, replacementRange: completion.range)
        if option.kind == .snippet {
            let offset = completion.range.location + option.insertion.utf16.count - 2
            view.setSelectedRange(NSRange(location: offset, length: 0))
        }
        dismiss()
    }

    func beginCompletion() {
        guard let view else { return }
        view.window?.makeFirstResponder(view)
        dismissedRange = nil
        if DynamicTemplate.completion(in: view.string, caret: view.selectedRange().location) != nil {
            selectionChanged()
        } else { view.insertBracePair() }
    }

    func formatFont(_ trait: NSFontTraitMask) {
        format(.font) { attribute in
            let manager = NSFontManager.shared
            let font = (attribute as? NSFont) ?? Self.baseFont
            return manager.traits(of: font).contains(trait) ? manager.convert(font, toNotHaveTrait: trait)
                : manager.convert(font, toHaveTrait: trait)
        }
    }

    func toggleAttribute(_ key: NSAttributedString.Key) {
        format(key) { ($0 as? Int ?? 0) == 0 ? NSUnderlineStyle.single.rawValue : nil }
    }

    private func format(_ key: NSAttributedString.Key, transform: (Any?) -> Any?) {
        guard let view, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        if range.length == 0 {
            var attributes = view.typingAttributes
            attributes[key] = transform(attributes[key])
            view.typingAttributes = attributes
        } else if view.shouldChangeText(in: range, replacementString: nil) {
            let firstValue = storage.attribute(key, at: range.location, effectiveRange: nil)
            if let value = transform(firstValue) { storage.addAttribute(key, value: value, range: range) }
            else { storage.removeAttribute(key, range: range) }
            view.didChangeText()
        }
        view.window?.makeFirstResponder(view)
    }

    func clearFormatting() {
        guard let view else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.baseFont]
        let range = view.selectedRange()
        if range.length > 0, view.shouldChangeText(in: range, replacementString: nil) {
            view.textStorage?.setAttributes(attributes, range: range)
            view.didChangeText()
        }
        view.typingAttributes = attributes
        view.window?.makeFirstResponder(view)
    }

    func addLink() {
        guard let view else { return }
        let range = view.selectedRange()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "https://example.com"
        let alert = NSAlert()
        alert.messageText = "添加链接"
        alert.accessoryView = field
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) else { return }
        view.window?.makeFirstResponder(view)
        view.setSelectedRange(range)
        if range.length == 0 {
            let previous = view.typingAttributes
            view.typingAttributes[.link] = url
            view.insertText(url.absoluteString, replacementRange: range)
            view.typingAttributes = previous
        } else { format(.link) { _ in url } }
    }
}

private final class SnippetNativeTextView: NSTextView {
    weak var editor: SnippetEditorState?
    private var focusedOnce = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !focusedOnce else { return }
        focusedOnce = true
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, self.window === window else { return }
            window?.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.editor?.focused = true; self?.editor?.selectionChanged() } }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            DispatchQueue.main.async { [weak self] in self?.editor?.focused = false; self?.editor?.selectionChanged() }
        }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        if editor?.key(event) == true { return }
        if event.characters == "{", !hasMarkedText(), selectedRange().length == 0,
           event.modifierFlags.intersection([.command, .control]).isEmpty {
            insertBracePair()
        } else { super.keyDown(with: event) }
    }

    func insertBracePair() {
        let range = selectedRange()
        insertText("{}", replacementRange: range)
        setSelectedRange(NSRange(location: range.location + 1, length: 0))
    }
}

private struct SnippetRichTextView: NSViewRepresentable {
    @Binding var draft: Snippet
    let state: SnippetEditorState

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.contentView.postsBoundsChangedNotifications = true

        let text = SnippetNativeTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 230))
        text.isRichText = true
        text.importsGraphics = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.drawsBackground = false
        text.font = SnippetEditorState.baseFont
        text.textColor = .labelColor
        text.insertionPointColor = .labelColor
        text.textContainerInset = NSSize(width: 0, height: 3)
        text.textContainer?.lineFragmentPadding = 1
        text.textContainer?.widthTracksTextView = true
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.setAccessibilityLabel("片段内容")
        if let original = SnippetPasteboard.attributedText(draft.richText), original.string == draft.text {
            text.textStorage?.setAttributedString(original)
        } else { text.string = draft.text }
        text.editor = state
        text.delegate = context.coordinator
        scroll.documentView = text
        state.view = text
        state.scrollView = scroll
        context.coordinator.observe(scroll.contentView)
        context.coordinator.highlight(text)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) { context.coordinator.parent = self }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SnippetRichTextView
        private var scrollObserver: NSObjectProtocol?
        init(parent: SnippetRichTextView) { self.parent = parent }

        deinit {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        }

        func observe(_ clip: NSClipView) {
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                    object: clip, queue: .main) { [weak self] _ in
                self?.parent.state.selectionChanged()
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView, let storage = text.textStorage else { return }
            var draft = parent.draft
            draft.text = text.string
            let full = NSRange(location: 0, length: storage.length)
            var formatted = false
            storage.enumerateAttributes(in: full) { attributes, _, stop in
                let font = attributes[.font] as? NSFont
                let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
                if !traits.intersection([.boldFontMask, .italicFontMask]).isEmpty ||
                    attributes[.link] != nil || (attributes[.underlineStyle] as? Int ?? 0) != 0 ||
                    (attributes[.strikethroughStyle] as? Int ?? 0) != 0 ||
                    (font != nil && font != SnippetEditorState.baseFont) {
                    formatted = true
                    stop.pointee = true
                }
            }
            draft.richText = formatted ? try? storage.data(from: full,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) : nil
            parent.draft = draft
            highlight(text)
            parent.state.selectionChanged()
        }

        func textViewDidChangeSelection(_ notification: Notification) { parent.state.selectionChanged() }

        func highlight(_ text: NSTextView) {
            guard let layout = text.layoutManager, let storage = text.textStorage else { return }
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
            for range in DynamicTemplate(text.string).placeholderRanges {
                for position in [range.location, NSMaxRange(range) - 1] {
                    layout.addTemporaryAttribute(.foregroundColor, value: NSColor.systemBlue,
                                                 forCharacterRange: NSRange(location: position, length: 1))
                }
            }
        }
    }
}
