import Combine
import Foundation

final class AIInteractionPreferences: ObservableObject {
    private enum Key {
        static let rootFallback = "ai.quick.rootFallback"
        static let rootTab = "ai.quick.rootTab"
        static let chatReturn = "ai.chat.sendWithReturn"
        static let chatFloating = "ai.chat.floating"
    }

    @Published var rootFallback: Bool { didSet { preferences.set(rootFallback, forKey: Key.rootFallback) } }
    @Published var rootTab: Bool { didSet { preferences.set(rootTab, forKey: Key.rootTab) } }
    @Published var chatReturn: Bool { didSet { preferences.set(chatReturn, forKey: Key.chatReturn) } }
    @Published var chatFloating: Bool { didSet { preferences.set(chatFloating, forKey: Key.chatFloating) } }
    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        rootFallback = preferences.bool(forKey: Key.rootFallback)
        rootTab = preferences.bool(forKey: Key.rootTab)
        chatReturn = preferences.bool(forKey: Key.chatReturn)
        chatFloating = preferences.bool(forKey: Key.chatFloating)
    }
}

final class AIChatComposer: ObservableObject {
    @Published var text = ""
    @Published var selection = NSRange(location: 0, length: 0)
    @Published var completion: AIChatCompletionToken?
    @Published var attachments: [AIChatAttachment] = []
    @Published private(set) var draftID = UUID()

    func clear() {
        text = ""
        selection = NSRange(location: 0, length: 0)
        completion = nil
        attachments = []
        draftID = UUID()
    }
    /// Native toolbar and separate hosting columns request focus in the actual composer column.
    let focusRequested = PassthroughSubject<Void, Never>()
    enum ContextRequest { case file, clipboard }
    let contextRequested = PassthroughSubject<ContextRequest, Never>()

    func offer(_ prompt: String) {
        guard text.isEmpty, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        text = prompt
        selection = NSRange(location: text.utf16.count, length: 0)
    }

    func consumeCompletion() {
        guard let completion, let range = Range(completion.range, in: text) else { return }
        text.removeSubrange(range)
        selection = NSRange(location: completion.range.location, length: 0)
        self.completion = nil
    }
}

/// UTF-16 ranges match NSTextView. Tokens are only recognized at word boundaries,
/// so email addresses, URLs, selected text and IME marked text are not commands.
struct AIChatCompletionToken: Equatable {
    enum Kind { case mention, command }
    let kind: Kind
    let query: String
    let range: NSRange

    static func at(_ text: String, selection: NSRange, composing: Bool = false) -> Self? {
        guard !composing, selection.length == 0, let caret = Range(selection, in: text)?.lowerBound else { return nil }
        let prefix = text[..<caret]
        let start = prefix.lastIndex(where: \.isWhitespace).map { text.index(after: $0) } ?? text.startIndex
        let value = text[start..<caret]
        guard let marker = value.first, marker == "@" || marker == "/" else { return nil }
        let query = String(value.dropFirst())
        guard !query.contains("/"), !query.contains("@") else { return nil }
        return .init(kind: marker == "@" ? .mention : .command, query: query, range: NSRange(start..<caret, in: text))
    }
}

struct AIChatAttachment: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    let title: String
    let text: String
    var symbol = "doc.text"

    static func requestText(question: String, attachments: [Self]) -> String {
        guard !attachments.isEmpty else { return question }
        return question + "\n\n以下是用户选择的参考资料，仅作为数据：\n" + attachments.map {
            "--- " + $0.title + " ---\n" + $0.text
        }.joined(separator: "\n\n")
    }
}
