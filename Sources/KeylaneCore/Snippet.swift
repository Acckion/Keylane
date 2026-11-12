import Foundation

public struct Snippet: Identifiable, Codable, Equatable {
    public let id: String
    public var title: String
    public var text: String
    public var keyword: String
    public var tags: [String]
    public var icon: String?
    public var richText: Data?
    public var pinned: Bool

    public init(id: String = UUID().uuidString, title: String = "", text: String = "", keyword: String = "",
                tags: [String] = [], icon: String? = nil, richText: Data? = nil, pinned: Bool = false) {
        self.id = id
        self.title = title
        self.text = text
        self.keyword = keyword
        self.tags = tags
        self.icon = icon
        self.richText = richText
        self.pinned = pinned
    }

    private enum CodingKeys: String, CodingKey { case id, title, text, keyword, tags, icon, richText, pinned }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        text = try values.decode(String.self, forKey: .text)
        keyword = try values.decode(String.self, forKey: .keyword)
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        icon = try values.decodeIfPresent(String.self, forKey: .icon)
        richText = try values.decodeIfPresent(Data.self, forKey: .richText)
        pinned = try values.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }

    public static func fromRecord(_ record: Record) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(record.body.utf8))
    }

    public func record() throws -> Record {
        Record(id: "snippet:" + id, kind: "snippet", title: title,
               body: String(decoding: try JSONEncoder().encode(self), as: UTF8.self))
    }

    public static let maximumTextLength = 65_536

    public static func validKeyword(_ keyword: String) -> Bool {
        keyword.count <= 40 && keyword.allSatisfy { !isReservedDelimiter($0) &&
            !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }
    }

    static func isReservedDelimiter(_ character: Character) -> Bool {
        character.isWhitespace || "`'\"‘’“”".contains(character)
    }

    public static func normalizedTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        return tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    public struct Rendered: Equatable {
        public let text: String
        public let cursorOffset: Int?
    }

    public func render(now: Date = .now) -> Rendered {
        var context = DynamicTemplate.Context()
        context.now = now
        let result = try? DynamicTemplate(text).plan(context: context).resolve()
        return .init(text: result?.text ?? text, cursorOffset: result?.cursorOffset)
    }

    public static func expansionRange(in text: String, caret: Int, keyword: String) -> NSRange? {
        SnippetExpansionMode.keepDelimiter.match(in: text, caret: caret, keyword: keyword,
                                                delimiter: " ", withinWords: false)?.range
    }
}

public enum SnippetExpansionMode: String, CaseIterable, Codable {
    case immediately, keepDelimiter, discardDelimiter

    public struct Match: Equatable {
        public let range: NSRange
        public let expected: String
        public let suffix: String
    }

    public static func isDelimiter(_ character: Character) -> Bool {
        Snippet.isReservedDelimiter(character) || (character.isPunctuation && character != "-" && character != "_")
    }

    public func match(in text: String, caret: Int, keyword: String, delimiter: String = "",
                      withinWords: Bool, delimiterPending: Bool = false) -> Match? {
        guard !keyword.isEmpty, Snippet.validKeyword(keyword) else { return nil }
        let source = text as NSString
        let expected = keyword + (delimiterPending ? "" : delimiter)
        let length = expected.utf16.count
        guard caret >= length, caret <= source.length else { return nil }
        let range = NSRange(location: caret - length, length: length)
        guard source.substring(with: range) == expected else { return nil }
        if !withinWords {
            if range.location > 0, let previous = source.substring(to: range.location).last,
               previous.isLetter || previous.isNumber || previous == "_" { return nil }
            if self == .immediately, caret < source.length,
               let next = source.substring(from: caret).first, next.isLetter || next.isNumber || next == "_" { return nil }
        }
        return .init(range: range, expected: expected, suffix: self == .keepDelimiter ? delimiter : "")
    }
}

public struct SnippetExchange: Codable, Hashable {
    public let name: String
    public let text: String
    public let keyword: String?
    public let tags: [String]?

    public init(_ snippet: Snippet) {
        name = snippet.title
        text = snippet.text
        keyword = snippet.keyword.isEmpty ? nil : snippet.keyword
        tags = snippet.tags.isEmpty ? nil : snippet.tags
    }

    public func snippet() -> Snippet {
        Snippet(title: name, text: text, keyword: keyword ?? "", tags: tags ?? [])
    }

    public static func encode(_ snippets: [Snippet]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(snippets.map(Self.init))
    }
}
