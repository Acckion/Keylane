import Foundation

/// Parses templates without accessing app state. The caller supplies a snapshot of the
/// relevant data, including browser content or the previous AI message when applicable.
public struct DynamicTemplate {
    public enum Usage {
        case snippet, quicklink, aiCommand
    }

    public enum Kind: String, CaseIterable {
        case calculator, uuid, clipboard, argument, cursor, snippet, date, time, datetime, day, selection
        case browserTab = "browser-tab"

        public func supports(_ usage: Usage) -> Bool {
            switch (self, usage) {
            case (.cursor, .quicklink), (.cursor, .aiCommand), (.selection, .snippet),
                 (.browserTab, .snippet), (.browserTab, .quicklink),
                 (.date, .aiCommand), (.time, .aiCommand), (.datetime, .aiCommand),
                 (.day, .aiCommand), (.uuid, .aiCommand): false
            default: true
            }
        }
    }

    public enum BrowserFormat: String { case markdown, text, html }

    public struct Context {
        public var now: Date = .now
        public var calendar: Calendar = .current
        public var locale: Locale = .current
        public var clipboard: (Int) -> String? = { _ in nil }
        public var selection: () -> String? = { nil }
        public var snippet: (String) -> String? = { _ in nil }
        public var browserTab: (BrowserFormat, String?) -> String? = { _, _ in nil }
        public var calculate: (String) -> String? = {
            if let unit = CalculatorConversion($0)?.unitResult { return unit }
            guard let result = Calculator.evaluate($0), result.isFinite else { return nil }
            return result.formatted(.number.precision(.fractionLength(0...12)).grouping(.never))
        }

        public init() {}
    }

    public struct Argument: Identifiable, Equatable {
        public let id: String
        public let title: String
        public let defaultValue: String?
        public let options: [String]
    }

    public struct Replacement {
        public let range: NSRange
        public let text: String
    }

    public struct Rendered {
        public let text: String
        public let cursorOffset: Int?
        public let replacements: [Replacement]
    }

    public enum Failure: LocalizedError, Equatable {
        case tooManyArguments
        case multipleCursors
        case conflictingArgument(String)
        case missingArgument(String)
        case invalidOption(String)
        case missingSnippet(String)
        case nestedSnippet(String)
        case missingBrowserTab
        case invalidCalculation

        public var errorDescription: String? {
            switch self {
            case .tooManyArguments: "一个模板最多使用三个不同的参数。"
            case .multipleCursors: "一个片段只能包含一个光标位置。"
            case .conflictingArgument(let name): "参数「\(name)」的默认值或选项不一致。"
            case .missingArgument(let name): "请输入「\(name)」。"
            case .invalidOption(let name): "请为「\(name)」选择一个有效选项。"
            case .missingSnippet(let name): "找不到文字片段「\(name)」。"
            case .nestedSnippet(let name): "文字片段「\(name)」已经引用了其他片段。"
            case .missingBrowserTab: "无法读取当前浏览器标签页。"
            case .invalidCalculation: "无法计算占位符中的表达式。"
            }
        }
    }

    private enum Modifier: String {
        case uppercase, lowercase, trim, raw
        case percentEncode = "percent-encode"
        case jsonStringify = "json-stringify"

        func apply(_ value: String) -> String {
            switch self {
            case .uppercase: value.uppercased()
            case .lowercase: value.lowercased()
            case .trim: value.trimmingCharacters(in: .whitespacesAndNewlines)
            case .percentEncode: DynamicTemplate.percentEncode(value)
            case .jsonStringify:
                Self.jsonString(value)
            case .raw: value
            }
        }

        private static func jsonString(_ value: String) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? value
        }
    }

    private struct Token {
        let range: NSRange
        let kind: Kind
        let attributes: [String: String]
        let modifiers: [Modifier]
    }

    private struct Part {
        let token: Token
        var argument: Argument?
        var included: [Part] = []
        var includedSource: String?
    }

    public struct Plan {
        public let arguments: [Argument]
        fileprivate let render: ([String: String]) throws -> Rendered

        public func resolve(_ values: [String: String] = [:]) throws -> Rendered { try render(values) }
    }

    private let source: String
    private let usage: Usage
    private let tokens: [Token]
    public var placeholderRanges: [NSRange] { tokens.map(\.range) }

    var legacySyntaxMigration: String {
        let result = NSMutableString(string: source)
        for token in tokens.reversed() {
            guard let name = token.attributes["name"] else { continue }
            let parameters = ["name=" + Self.quoted(name)] +
                (token.attributes["default"].map { ["default=" + Self.quoted($0)] } ?? [])
            result.replaceCharacters(in: token.range, with: "{argument " + parameters.joined(separator: " ") + "}")
        }
        return result as String
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static let braces = try! NSRegularExpression(pattern: #"\{(?:[^{}"\r\n]|"(?:[^"\\\r\n]|\\.)*")*\}"#)
    private static let attributes = try! NSRegularExpression(pattern: #"^\s+([a-z][a-z-]*)=(?:"((?:[^"\\]|\\.)*)"|([^\s|{}"]+))"#)
    private static let offset = try! NSRegularExpression(pattern: #"^[+-][0-9]+[mhdMy]$"#)
    private static let localeIDs = Set(Locale.availableIdentifiers.map { $0.replacingOccurrences(of: "_", with: "-").lowercased() })
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public init(_ source: String, usage: Usage = .snippet, legacyQuicklinkArguments: Bool = false,
                legacyQuicklinkOnly: Bool = false) {
        self.source = source
        self.usage = usage
        let text = source as NSString
        tokens = Self.braces.matches(in: source, range: NSRange(location: 0, length: text.length)).compactMap { match in
            let inner = text.substring(with: NSRange(location: match.range.location + 1, length: match.range.length - 2))
            return Self.parse(inner, range: match.range, usage: usage, legacy: legacyQuicklinkArguments || legacyQuicklinkOnly,
                              legacyOnly: legacyQuicklinkOnly)
        }
    }

    private static func parse(_ input: String, range: NSRange, usage: Usage, legacy: Bool, legacyOnly: Bool) -> Token? {
        let inner = input.trimmingCharacters(in: .whitespaces)
        let name = inner.prefix { !$0.isWhitespace && $0 != "|" }
        guard !legacyOnly, let kind = Kind(rawValue: String(name)) else {
            let pieces = input.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard legacy, let name = pieces.first, !name.isEmpty,
                  name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }) else { return nil }
            var values = ["name": String(name)]
            guard !input.contains("{"), !input.contains("}") else { return nil }
            if pieces.count == 2 { values["default"] = String(pieces[1]) }
            return Token(range: range, kind: .argument, attributes: values, modifiers: [])
        }
        guard kind.supports(usage) else { return nil }
        var remainder = String(inner.dropFirst(name.count))
        var values: [String: String] = [:]
        while let match = attributes.firstMatch(in: remainder, range: NSRange(remainder.startIndex..., in: remainder)) {
            let text = remainder as NSString
            let key = text.substring(with: match.range(at: 1))
            guard values[key] == nil else { return nil }
            let quoted = match.range(at: 2)
            values[key] = quoted.location == NSNotFound ? text.substring(with: match.range(at: 3)) :
                text.substring(with: quoted).replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            remainder = text.substring(from: match.range.length)
        }
        let tail = remainder.trimmingCharacters(in: .whitespaces)
        let modifierNames = tail.isEmpty ? [] : tail.dropFirst().split(separator: "|", omittingEmptySubsequences: false)
        let modifiers = modifierNames.compactMap { Modifier(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
        guard tail.isEmpty || (tail.first == "|" && modifiers.count == modifierNames.count),
              valid(values, for: kind) else { return nil }
        return Token(range: range, kind: kind, attributes: values, modifiers: modifiers)
    }

    private static func valid(_ values: [String: String], for kind: Kind) -> Bool {
        let keys = Set(values.keys)
        switch kind {
        case .argument:
            return keys.isSubset(of: ["name", "default", "options"]) && values["name"] != "" &&
                values["name"]?.contains("\u{0}") != true &&
                (values["options"] == nil || !options(values["options"]).isEmpty)
        case .snippet: return keys == ["name"] && values["name"]?.isEmpty == false
        case .calculator: return keys.isSubset(of: ["expression"]) && values["expression"] != ""
        case .clipboard:
            return keys.isSubset(of: ["offset"]) && (values["offset"] == nil || Int(values["offset"] ?? "").map { $0 >= 0 } == true)
        case .date, .time, .datetime, .day:
            guard keys.isSubset(of: ["format", "locale", "offset"]), values["format"] != "",
                  values["format"] == nil || values["locale"] == nil else { return false }
            if let locale = values["locale"] {
                let base = locale.lowercased().components(separatedBy: "-u-")[0]
                guard !locale.contains("_"), localeIDs.contains(base) else { return false }
            }
            return values["offset"].map { dateOffsets($0) != nil } ?? true
        case .browserTab:
            return keys.isSubset(of: ["format", "selector"]) && values["selector"] != "" &&
                (values["format"].map { BrowserFormat(rawValue: $0) != nil } ?? true)
        case .uuid, .cursor, .selection: return keys.isEmpty
        }
    }

    private static func options(_ source: String?) -> [String] {
        var seen: Set<String> = []
        return (source ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public func plan(context: Context = .init(), allowMoreLegacyArguments: Bool = false) throws -> Plan {
        var arguments: [Argument] = []
        let parts = try makeParts(context: context, arguments: &arguments, referencing: false)
        guard allowMoreLegacyArguments || arguments.count <= 3 else { throw Failure.tooManyArguments }
        let cursorCount = parts.reduce(0) { count, part in
            count + (part.token.kind == .cursor ? 1 : part.included.filter { $0.token.kind == .cursor }.count)
        }
        if usage == .snippet, cursorCount > 1 { throw Failure.multipleCursors }
        return Plan(arguments: arguments) { values in
            let definitions = Dictionary(uniqueKeysWithValues: arguments.map { ($0.id, $0) })
            return try Self.render(source, parts: parts, context: context, usage: usage, values: values,
                                   definitions: definitions)
        }
    }

    private func makeParts(context: Context, arguments: inout [Argument], referencing: Bool) throws -> [Part] {
        try tokens.map { token in
            var part = Part(token: token)
            if token.kind == .argument || (token.kind == .calculator && token.attributes["expression"] == nil) {
                let name = token.attributes["name"]
                let id = name ?? "\u{0}\(arguments.count + 1)"
                let title = name ?? (token.kind == .calculator ? "计算表达式" : "参数 \(arguments.count + 1)")
                let argument = Argument(id: id, title: title, defaultValue: token.attributes["default"],
                                        options: Self.options(token.attributes["options"]))
                if let index = arguments.firstIndex(where: { $0.id == id }) {
                    let previous = arguments[index]
                    if let left = previous.defaultValue, let right = argument.defaultValue, left != right {
                        throw Failure.conflictingArgument(title)
                    }
                    if !previous.options.isEmpty && !argument.options.isEmpty && previous.options != argument.options {
                        throw Failure.conflictingArgument(title)
                    }
                    arguments[index] = Argument(id: id, title: title,
                                                defaultValue: previous.defaultValue ?? argument.defaultValue,
                                                options: previous.options.isEmpty ? argument.options : previous.options)
                } else { arguments.append(argument) }
                part.argument = argument
            }
            if token.kind == .snippet, let name = token.attributes["name"] {
                guard let content = context.snippet(name) else { throw Failure.missingSnippet(name) }
                let template = DynamicTemplate(content, usage: .snippet)
                guard !referencing, !template.tokens.contains(where: { $0.kind == .snippet }) else {
                    throw Failure.nestedSnippet(name)
                }
                part.includedSource = content
                part.included = try template.makeParts(context: context, arguments: &arguments, referencing: true)
            }
            return part
        }
    }

    private static func render(_ source: String, parts: [Part], context: Context, usage: Usage,
                               values: [String: String], definitions: [String: Argument]) throws -> Rendered {
        let text = NSMutableString(string: source)
        var replacements: [Replacement] = []
        var cursor: Int?
        var shift = 0
        for part in parts {
            let token = part.token
            let argumentValue: String?
            if let id = part.argument?.id, let argument = definitions[id] {
                let input = values[argument.id]
                guard let value = input.flatMap({ $0.isEmpty ? nil : $0 }) ?? argument.defaultValue else {
                    throw Failure.missingArgument(argument.title)
                }
                guard argument.options.isEmpty || argument.options.contains(value) else { throw Failure.invalidOption(argument.title) }
                argumentValue = value
            } else { argumentValue = nil }

            var value: String
            var includedCursor: Int?
            switch token.kind {
            case .argument: value = argumentValue ?? ""
            case .cursor:
                if cursor == nil { cursor = token.range.location + shift }
                value = ""
            case .clipboard: value = context.clipboard(token.attributes["offset"].flatMap(Int.init) ?? 0) ?? ""
            case .selection: value = context.selection() ?? ""
            case .uuid: value = UUID().uuidString
            case .date, .time, .datetime, .day: value = formatDate(token, context: context)
            case .calculator:
                guard let input = token.attributes["expression"] ?? argumentValue,
                      let result = context.calculate(input) else { throw Failure.invalidCalculation }
                value = result
            case .snippet:
                let nested = try render(part.includedSource ?? "", parts: part.included, context: context, usage: .snippet, values: values,
                                        definitions: definitions)
                value = nested.text
                if token.modifiers.isEmpty && usage == .snippet { includedCursor = nested.cursorOffset }
            case .browserTab:
                let format = token.attributes["format"].flatMap(BrowserFormat.init(rawValue:)) ?? .markdown
                guard let content = context.browserTab(format, token.attributes["selector"]) else { throw Failure.missingBrowserTab }
                value = content
            }

            value = token.modifiers.reduce(value) { $1.apply($0) }
            if token.kind != .cursor, !token.modifiers.contains(.raw) {
                switch usage {
                case .snippet: break
                case .quicklink: if !token.modifiers.contains(.percentEncode) { value = percentEncode(value) }
                case .aiCommand: value = "\"\"\"" + value + "\"\"\""
                }
            }
            if cursor == nil, let includedCursor { cursor = token.range.location + shift + includedCursor }
            replacements.append(.init(range: token.range, text: value))
            shift += value.utf16.count - token.range.length
        }
        for replacement in replacements.reversed() { text.replaceCharacters(in: replacement.range, with: replacement.text) }
        return Rendered(text: text as String, cursorOffset: cursor, replacements: replacements)
    }

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func dateOffsets(_ source: String) -> [(Calendar.Component, Int)]? {
        let units: [Character: Calendar.Component] = ["m": .minute, "h": .hour, "d": .day, "M": .month, "y": .year]
        let values = source.split(whereSeparator: \.isWhitespace)
        guard !values.isEmpty else { return nil }
        var result: [(Calendar.Component, Int)] = []
        for value in values {
            let text = String(value)
            guard offset.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil,
                  let unit = text.last.flatMap({ units[$0] }), let count = Int(text.dropLast()) else { return nil }
            result.append((unit, count))
        }
        return result
    }

    private static func formatDate(_ token: Token, context: Context) -> String {
        let formatter = DateFormatter()
        formatter.locale = token.attributes["locale"].map(Locale.init(identifier:)) ?? context.locale
        formatter.timeZone = context.calendar.timeZone
        if let custom = token.attributes["format"] { formatter.dateFormat = custom }
        else {
            switch token.kind {
            case .date: formatter.dateStyle = .medium
            case .time: formatter.timeStyle = .short
            case .datetime: formatter.dateStyle = .medium; formatter.timeStyle = .short
            case .day: formatter.setLocalizedDateFormatFromTemplate("EEEE")
            default: break
            }
        }
        let now = (token.attributes["offset"].flatMap(dateOffsets) ?? []).reduce(context.now) {
            context.calendar.date(byAdding: $1.0, value: $1.1, to: $0) ?? $0
        }
        return formatter.string(from: now)
    }

    /// Finds the replacement span at an insertion point without treating braces in quoted attributes as new tokens.
    public static func completion(in source: String, caret: Int) -> (range: NSRange, prefix: String)? {
        let text = source as NSString
        guard caret > 0, caret <= text.length else { return nil }
        let before = text.substring(to: caret) as NSString
        let opening = before.range(of: "{", options: .backwards)
        guard opening.location != NSNotFound else { return nil }
        let prefix = before.substring(from: NSMaxRange(opening))
        guard prefix.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") }) else { return nil }
        let after = text.substring(from: caret).prefix { $0.isASCII && ($0.isLetter || $0 == "-") }
        var end = caret + after.utf16.count
        if end < text.length && text.character(at: end) == 125 { end += 1 }
        return (NSRange(location: opening.location, length: end - opening.location), prefix)
    }
}
