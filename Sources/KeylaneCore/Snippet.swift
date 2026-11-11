import Foundation

public struct Snippet: Identifiable, Codable, Equatable {
    public let id: String
    public var title: String
    public var text: String
    public var keyword: String

    public init(id: String = UUID().uuidString, title: String = "", text: String = "", keyword: String = "") {
        self.id = id
        self.title = title
        self.text = text
        self.keyword = keyword
    }

    public static func fromRecord(_ record: Record) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(record.body.utf8))
    }

    public func record() throws -> Record {
        Record(id: "snippet:" + id, kind: "snippet", title: title,
               body: String(decoding: try JSONEncoder().encode(self), as: UTF8.self))
    }

    public static func validKeyword(_ keyword: String) -> Bool {
        keyword.isEmpty || (keyword.utf8.count <= 40 && keyword.utf8.allSatisfy {
            (33...126).contains($0)
        })
    }

    public struct Rendered: Equatable {
        public let text: String
        public let cursorOffset: Int?
    }

    public func render(now: Date = .now) -> Rendered {
        var expanded = text
        if text.contains("{date}") || text.contains("{time}") {
            expanded = expanded.replacingOccurrences(of: "{date}", with: now.formatted(date: .numeric, time: .omitted))
                .replacingOccurrences(of: "{time}", with: now.formatted(date: .omitted, time: .shortened))
        }
        let offset = expanded.range(of: "{cursor}").map { expanded[..<$0.lowerBound].utf16.count }
        return .init(text: expanded.replacingOccurrences(of: "{cursor}", with: ""), cursorOffset: offset)
    }

    /// The triggering Space is already in the text field. Only replace a complete token.
    public static func expansionRange(in text: String, caret: Int, keyword: String) -> NSRange? {
        guard !keyword.isEmpty, validKeyword(keyword) else { return nil }
        let source = text as NSString
        let trigger = keyword + " "
        let length = trigger.utf16.count
        guard caret >= length, caret <= source.length else { return nil }
        let start = caret - length
        let range = NSRange(location: start, length: length)
        guard source.substring(with: range) == trigger else { return nil }
        if start > 0 {
            let previous = source.character(at: start - 1)
            guard let scalar = Unicode.Scalar(previous), CharacterSet.whitespacesAndNewlines.contains(scalar) else { return nil }
        }
        return range
    }
}
