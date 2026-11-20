import Foundation
import KeylaneCore

/// Raw snippet text is data: placeholders are never evaluated during AI preparation.
enum SnippetAIContextSource {
    static let moduleID = ModuleID(rawValue: "keylane.snippets")
    static func make(id: String, read: @escaping @MainActor () -> Snippet?) -> AIActionSource {
        .init(moduleID: moduleID, load: {
            guard let snippet = read(), snippet.id == id else { throw AIActionError.staleSource }
            let context = AIActionContext(sourceID: id, title: snippet.title.isEmpty ? "所选文字片段" : snippet.title, text: snippet.text)
            try context.validate(maximumBytes: 32_000)
            return context
        }, isCurrent: { context in
            guard let snippet = read(), snippet.id == id else { return false }
            return AIActionContext.digest(snippet.text) == context.fingerprint
        })
    }
}
