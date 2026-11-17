import AppKit
import CoreServices
import Darwin
import Foundation

struct DictionaryWord: Codable, Equatable, Identifiable {
    let word: String
    let entries: [DictionaryEntry]
    var id: String { word }
    var definition: String { entries.map(\.plainText).joined(separator: "\n\n") }
    var preview: String {
        let excerpt = entries.first?.paragraphs.prefix(5).map { $0.map(\.text).joined() }.joined(separator: " ") ?? ""
        let text = excerpt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let match = text.range(of: word, options: [.caseInsensitive, .anchored]),
           match.upperBound < text.endIndex, text[match.upperBound].isWhitespace {
            return text[match.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        return text
    }
}

struct DictionaryEntry: Codable, Equatable, Identifiable {
    struct Run: Codable, Equatable {
        enum Style: String, Codable { case regular, heading, secondary, example }
        let text: String
        let style: Style
    }

    let id: String
    let sourceID: String
    let source: String
    let paragraphs: [[Run]]
    var plainText: String { paragraphs.map { $0.map(\.text).joined() }.joined(separator: "\n") }

    static func plain(_ text: String) -> Self {
        .init(id: "system", sourceID: "system", source: "系统词典",
              paragraphs: text.split(whereSeparator: \.isNewline).map { [Run(text: String($0), style: .regular)] })
    }
}

enum DictionaryProcess {
    static let argument = "--dictionary-lookup"
    private static let maximumResponseSize = 2 * 1024 * 1024

    static func run() -> Never {
        guard let input = readLine(), let payload = Data(base64Encoded: input),
              let term = try? JSONDecoder().decode(String.self, from: payload),
              (1...DictionaryController.maximumTermLength).contains(term.utf16.count) else { exit(2) }
        let words = SystemDictionary()?.search(term) ?? []
        guard let data = try? JSONEncoder().encode(words), data.count <= maximumResponseSize else { exit(2) }
        FileHandle.standardOutput.write(data)
        exit(0)
    }

    static func search(_ term: String) -> [DictionaryWord] {
        let words = lookupInChild(term)
        if words.contains(where: { $0.word.caseInsensitiveCompare(term) == .orderedSame }) { return words }
        guard let definition = DictionaryController.definition(for: term) else { return words }
        return [.init(word: term, entries: [.plain(definition)])] + words
    }

    private static func lookupInChild(_ term: String) -> [DictionaryWord] {
        guard let executable = Bundle.main.executableURL,
              let payload = try? JSONEncoder().encode(term) else { return [] }
        let process = Process()
        process.executableURL = executable
        process.arguments = [argument]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let request = ExtensionProcessRequest()
        do { try request.launch(process) } catch { return [] }
        defer { request.finished() }
        let timeout = DispatchWorkItem { request.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.5, execute: timeout)
        defer { timeout.cancel() }
        try? input.fileHandleForWriting.write(contentsOf: Data((payload.base64EncodedString() + "\n").utf8))
        try? input.fileHandleForWriting.close()

        var result = Data()
        while let chunk = try? output.fileHandleForReading.read(upToCount: 16384), !chunk.isEmpty {
            if result.count + chunk.count > maximumResponseSize { request.cancel(); break }
            result.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, !request.isCancelled else { return [] }
        return (try? JSONDecoder().decode([DictionaryWord].self, from: result)) ?? []
    }
}

/// The undocumented DictionaryServices entry points are only used by the lookup child process.
private final class SystemDictionary {
    private typealias Dictionaries = @convention(c) (CFDictionary?) -> Unmanaged<CFArray>?
    private typealias Read = @convention(c) (CFTypeRef) -> Unmanaged<CFString>?
    private typealias Records = @convention(c) (CFTypeRef, CFString, UnsafeRawPointer?, UnsafeRawPointer?) -> Unmanaged<CFArray>?
    private let library: UnsafeMutableRawPointer
    private let dictionaries: Dictionaries
    private let name: Read
    private let identifier: Read
    private let records: Records
    private let markup: Read

    init?() {
        let path = "/System/Library/Frameworks/CoreServices.framework/Frameworks/DictionaryServices.framework/DictionaryServices"
        guard let library = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { return nil }
        guard let dictionaries = dlsym(library, "DCSCopyActiveDictionaries"),
              let name = dlsym(library, "DCSDictionaryGetShortName"),
              let identifier = dlsym(library, "DCSDictionaryGetIdentifier"),
              let records = dlsym(library, "DCSCopyRecordsForSearchString"),
              let markup = dlsym(library, "DCSRecordCopyData") else {
            dlclose(library)
            return nil
        }
        self.library = library
        self.dictionaries = unsafeBitCast(dictionaries, to: Dictionaries.self)
        self.name = unsafeBitCast(name, to: Read.self)
        self.identifier = unsafeBitCast(identifier, to: Read.self)
        self.records = unsafeBitCast(records, to: Records.self)
        self.markup = unsafeBitCast(markup, to: Read.self)
    }

    deinit { dlclose(library) }

    func search(_ term: String) -> [DictionaryWord] {
        guard let active = dictionaries(nil)?.takeRetainedValue() as? [AnyObject], !active.isEmpty else { return [] }
        let sources = active.compactMap { dictionary -> (object: AnyObject, id: String, title: String)? in
            guard let id = identifier(dictionary)?.takeUnretainedValue() as String?,
                  let title = name(dictionary)?.takeUnretainedValue() as String? else { return nil }
            return (dictionary, id, title)
        }
        var seen: Set<String> = []
        var result: [DictionaryWord] = []
        for word in [term] + completions(term) {
            guard seen.insert(word.lowercased()).inserted else { continue }
            let entries = sources.flatMap { source -> [DictionaryEntry] in
                guard let found = records(source.object, word as CFString, nil, nil)?.takeRetainedValue() as? [AnyObject] else { return [] }
                return found.prefix(4).enumerated().compactMap { index, record in
                    guard let html = markup(record)?.takeRetainedValue() as String?,
                          html.utf8.count <= 100_000, let paragraphs = DictionaryMarkup.paragraphs(html) else { return nil }
                    return .init(id: "\(source.id)-\(index)", sourceID: source.id, source: source.title, paragraphs: paragraphs)
                }
            }
            if !entries.isEmpty { result.append(.init(word: word, entries: entries)) }
            if result.count == 12 { break }
        }
        return result
    }

    private func completions(_ term: String) -> [String] {
        guard term.count >= 2, term.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else { return [] }
        let words = NSSpellChecker.shared.completions(forPartialWordRange: NSRange(location: 0, length: term.utf16.count),
                                                    in: term, language: "en_US", inSpellDocumentWithTag: 0) ?? []
        return words.filter { $0.lowercased().hasPrefix(term.lowercased()) }
            .sorted { $0.count == $1.count ? $0.localizedStandardCompare($1) == .orderedAscending : $0.count < $1.count }
            .prefix(25).map { $0 }
    }
}

private final class DictionaryMarkup: NSObject, XMLParserDelegate {
    private struct Element {
        let style: DictionaryEntry.Run.Style
        let section: Bool
        let ignored: Bool
    }
    private var stack: [Element] = []
    private var paragraph: [DictionaryEntry.Run] = []
    private var result: [[DictionaryEntry.Run]] = []
    private var entryDepth: Int?
    private static let breaks: Set<String> = ["p", "br", "li", "div"]
    private static let sectionClasses: Set<String> = ["hg", "hwg", "posg", "se2", "se3",
                                                     "exg", "etym", "sub", "phrase"]

    static func paragraphs(_ html: String) -> [[DictionaryEntry.Run]]? {
        let reader = DictionaryMarkup()
        let parser = XMLParser(data: Data(html.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse() else { return nil }
        reader.finishParagraph()
        return reader.result.isEmpty ? nil : reader.result
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        let classes = Set((attributes["class"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
        let section = Self.breaks.contains(name) || !classes.isDisjoint(with: Self.sectionClasses)
        let ignored = stack.last?.ignored == true || ["script", "style", "d:prn"].contains(name)
        var style = stack.last?.style ?? .regular
        if classes.contains("hw") || name == "strong" || name == "b" { style = .heading }
        else if !classes.isDisjoint(with: ["ex", "exg"]) || name == "i" || name == "em" { style = .example }
        else if !classes.isDisjoint(with: ["pr", "prx", "ph", "pos", "posg", "sn", "label", "gram"]) { style = .secondary }
        if name == "d:entry" { entryDepth = stack.count + 1 }
        if entryDepth != nil && section && !ignored { finishParagraph() }
        stack.append(.init(style: style, section: section, ignored: ignored))
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if entryDepth != nil, let element = stack.last, element.section && !element.ignored { finishParagraph() }
        if entryDepth == stack.count { finishParagraph(); entryDepth = nil }
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard entryDepth != nil, let element = stack.last, !element.ignored else { return }
        let text = string.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if let last = paragraph.last, last.style == element.style {
            paragraph[paragraph.count - 1] = .init(text: last.text + text, style: last.style)
        } else {
            paragraph.append(.init(text: text, style: element.style))
        }
    }

    private func finishParagraph() {
        if paragraph.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            result.append(paragraph)
        }
        paragraph.removeAll(keepingCapacity: true)
    }
}
