import Foundation
import zlib

/// A bounded, data-only OOXML reader. Never extracts files, resolves a URL,
/// evaluates a formula, or launches an Office/import process.
public enum AIFileOfficeText {
    public static let extensions: Set<String> = ["docx", "xlsx", "pptx"]
    public static func sections(_ data: Data, extension kind: String, maximumTextBytes: Int = 2_097_152,
                                check: @escaping () throws -> Void = { try Task.checkCancellation() }) throws -> [String] {
        guard extensions.contains(kind) else { throw AIFileDocumentText.Failure.unsupported }
        guard (1...2_097_152).contains(maximumTextBytes), data.count <= 8_388_608 else { throw AIFileDocumentText.Failure.tooLarge }
        var archive = try OfficeZIP(data, check: check)
        guard archive.names.contains("[Content_Types].xml") else { throw AIFileDocumentText.Failure.unsupported }
        let budget = OfficeXMLBudget(check: check)
        func xml(_ path: String) throws -> OfficeXMLNode { try OfficeXMLNode.parse(archive.read(path, check: check), budget: budget) }
        var result: [String] = [], total = 0
        func append(_ value: String) throws {
            try check(); total += value.utf8.count
            guard total <= maximumTextBytes else { throw AIFileDocumentText.Failure.tooLarge }
            result.append(value)
        }
        func sink(_ title: String) throws -> OfficeTextSink {
            var sink = OfficeTextSink(limit: maximumTextBytes)
            try sink.append(title + "\n")
            return sink
        }
        switch kind {
        case "docx":
            let document = try xml("word/document.xml")
            try document.require("document", family: "wordprocessingml")
            guard let body = document.children.first(where: { $0.name == "body" }) else { throw AIFileDocumentText.Failure.unsupported }
            var text = try sink("[Document]")
            for paragraph in body.descendants("p") { try check(); try text.append(paragraph.textRuns() + "\n") }
            try append(text.value)
        case "xlsx":
            let workbook = try xml("xl/workbook.xml"); try workbook.require("workbook", family: "spreadsheetml")
            let relations = try OfficeXMLNode.relationships(xml("xl/_rels/workbook.xml.rels"), directory: "xl", prefix: "xl/worksheets/", type: "worksheet")
            var strings: [String] = []
            if archive.names.contains("xl/sharedStrings.xml") {
                let shared = try xml("xl/sharedStrings.xml"); try shared.require("sst", family: "spreadsheetml")
                strings = shared.children.filter { $0.name == "si" }.map { $0.textRuns() }
                guard strings.count <= 50_000 else { throw AIFileDocumentText.Failure.tooLarge }
            }
            let sheets = workbook.descendants("sheet")
            guard !sheets.isEmpty, sheets.count <= 100 else { throw AIFileDocumentText.Failure.tooLarge }
            for sheet in sheets {
                try check()
                guard let id = sheet.relationshipID, let path = relations[id] else { throw AIFileDocumentText.Failure.unsupported }
                let content = try xml(path); try content.require("worksheet", family: "spreadsheetml")
                var text = try sink("[Sheet: " + (sheet.attributes["name"] ?? "Untitled") + "]")
                for row in content.children.filter({ $0.name == "sheetData" }).flatMap(\.children).filter({ $0.name == "row" }) {
                    for cell in row.children where cell.name == "c" {
                        try check()
                        let raw = cell.children.first(where: { $0.name == "v" })?.plainText ?? ""
                        let value: String
                        switch cell.attributes["t"] {
                        case "s":
                            guard let index = Int(raw), strings.indices.contains(index) else { throw AIFileDocumentText.Failure.unsupported }
                            value = strings[index]
                        case "inlineStr": value = cell.textRuns()
                        case "b": value = raw == "1" ? "TRUE" : raw == "0" ? "FALSE" : raw
                        default: value = raw.isEmpty && cell.children.contains(where: { $0.name == "f" }) ? "[formula: no cached value]" : raw
                        }
                        if !value.isEmpty { try text.append((cell.attributes["r"] ?? "?") + "\t" + value + "\n") }
                    }
                }
                try append(text.value)
            }
        default:
            let presentation = try xml("ppt/presentation.xml"); try presentation.require("presentation", family: "presentationml")
            let relations = try OfficeXMLNode.relationships(xml("ppt/_rels/presentation.xml.rels"), directory: "ppt", prefix: "ppt/slides/", type: "slide")
            let slides = presentation.descendants("sldId")
            guard !slides.isEmpty, slides.count <= 100 else { throw AIFileDocumentText.Failure.tooLarge }
            for (index, slide) in slides.enumerated() {
                try check()
                guard let id = slide.relationshipID, let path = relations[id] else { throw AIFileDocumentText.Failure.unsupported }
                let content = try xml(path); try content.require("sld", family: "presentationml")
                var text = try sink("[Slide " + String(index + 1) + "]")
                for paragraph in content.descendants("p") { try text.append(paragraph.textRuns() + "\n") }
                try append(text.value)
            }
        }
        guard result.contains(where: { $0.split(separator: "\n").dropFirst().contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }) else { throw AIFileDocumentText.Failure.empty }
        return result
    }
}

private struct OfficeTextSink {
    let limit: Int
    private var parts: [String] = []
    private var size = 0
    init(limit: Int) { self.limit = limit }
    mutating func append(_ value: String) throws {
        size += value.utf8.count
        guard size <= limit else { throw AIFileDocumentText.Failure.tooLarge }
        parts.append(value)
    }
    var value: String { parts.joined() }
}

private final class OfficeXMLBudget {
    let check: () throws -> Void
    var nodes = 0
    let deadline = ProcessInfo.processInfo.systemUptime + 10
    init(check: @escaping () throws -> Void) { self.check = check }
    func tick() throws {
        try check()
        guard nodes <= 150_000, ProcessInfo.processInfo.systemUptime < deadline else { throw AIFileDocumentText.Failure.tooLarge }
    }
}
private final class OfficeXMLNode: NSObject, XMLParserDelegate {
    var name = "", namespace = "", attributes: [String: String] = [:], chunks: [String] = [], children: [OfficeXMLNode] = []
    var stack: [OfficeXMLNode] = []
    var root: OfficeXMLNode?, failure: Error?, bytes = 0
    var budget: OfficeXMLBudget?
    var namespaces: [String: [String]] = [:]
    var relationshipID: String?
    static func parse(_ data: Data, budget: OfficeXMLBudget) throws -> OfficeXMLNode {
        guard data.count <= 4_194_304, let text = String(data: data, encoding: .utf8),
              text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw AIFileDocumentText.Failure.unsupported }
        try budget.tick()
        let delegate = OfficeXMLNode(); delegate.budget = budget
        let parser = XMLParser(data: data); parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false; parser.externalEntityResolvingPolicy = .never; parser.delegate = delegate
        let valid = parser.parse()
        if let failure = delegate.failure { throw failure }
        guard valid, let root = delegate.root else { throw AIFileDocumentText.Failure.unsupported }
        try budget.tick(); return root
    }
    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) { namespaces[prefix, default: []].append(namespaceURI) }
    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { _ = namespaces[prefix]?.popLast() }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String]) {
        do {
            budget!.nodes += 1; try budget!.tick()
            guard stack.count < 128, attributeDict.count <= 64 else { throw AIFileDocumentText.Failure.tooLarge }
            let node = OfficeXMLNode(); node.name = elementName; node.namespace = namespaceURI ?? ""; node.attributes = attributeDict
            for (key, value) in attributeDict {
                let parts = key.split(separator: ":", maxSplits: 1)
                if parts.count == 2, parts[1] == "id", let uri = namespaces[String(parts[0])]?.last,
                   ["http://schemas.openxmlformats.org/officeDocument/2006/relationships", "http://purl.oclc.org/ooxml/officeDocument/relationships"].contains(uri) { node.relationshipID = value }
            }
            if let parent = stack.last { parent.children.append(node) } else { root = node }
            stack.append(node)
        } catch { failure = error; parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        do {
            try budget!.tick(); bytes += string.utf8.count
            guard bytes <= 4_194_304 else { throw AIFileDocumentText.Failure.tooLarge }
            stack.last?.chunks.append(string)
        } catch { failure = error; parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { failure = AIFileDocumentText.Failure.unsupported; parser.abortParsing(); return }; self.parser(parser, foundCharacters: text)
    }
    func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) { if !stack.isEmpty { stack.removeLast() } }
    func parser(_ parser: XMLParser, resolveExternalEntityName: String, systemID: String?) -> Data? { failure = AIFileDocumentText.Failure.unsupported; parser.abortParsing(); return nil }
    var plainText: String { chunks.joined() }
    func descendants(_ name: String) -> [OfficeXMLNode] {
        children.filter { $0.name != "del" }.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }
    func textRuns() -> String {
        if name == "rPh" || name == "del" { return "" }
        if name == "t" { return plainText }
        if name == "tab" { return "\t" }
        if name == "br" || name == "cr" { return "\n" }
        return children.map { $0.textRuns() }.joined()
    }
    func require(_ name: String, family: String) throws {
        guard self.name == name, namespace == "http://schemas.openxmlformats.org/\(family)/2006/main" || namespace == "http://purl.oclc.org/ooxml/\(family)/main" else { throw AIFileDocumentText.Failure.unsupported }
    }
    static func relationships(_ root: OfficeXMLNode, directory: String, prefix: String, type: String) throws -> [String: String] {
        guard root.name == "Relationships", root.namespace == "http://schemas.openxmlformats.org/package/2006/relationships" else { throw AIFileDocumentText.Failure.unsupported }
        var result: [String: String] = [:]
        for relation in root.children where relation.name == "Relationship" && relation.attributes["Type"]?.hasSuffix("/" + type) == true {
            guard ["", "Internal"].contains(relation.attributes["TargetMode"] ?? ""), let id = relation.attributes["Id"], result[id] == nil,
                  let target = relation.attributes["Target"], !target.contains(":"), !target.contains("%"), !target.contains("\\") else { throw AIFileDocumentText.Failure.unsupported }
            var components: [String] = target.hasPrefix("/") ? [] : [directory]
            for part in target.split(separator: "/") {
                if part == "." { continue }
                if part == ".." { guard !components.isEmpty else { throw AIFileDocumentText.Failure.unsupported }; components.removeLast() }
                else { components.append(String(part)) }
            }
            let path = components.joined(separator: "/")
            guard path.hasPrefix(prefix), path.hasSuffix(".xml") else { throw AIFileDocumentText.Failure.unsupported }
            result[id] = path
        }
        return result
    }
}

private struct OfficeZIP {
    private struct Entry { let offset: Int; let size: Int; let plain: Int; let method: Int; let crc: UInt32 }
    private let data: Data
    private var entries: [String: Entry] = [:]
    private var extracted = 0
    var names: Set<String> { Set(entries.keys) }
    init(_ input: Data, check: () throws -> Void) throws {
        let data = Data(input) // Normalize slices before integer ZIP offsets.
        self.data = data
        guard data.count >= 22 else { throw AIFileDocumentText.Failure.unsupported }
        func word(_ at: Int, _ length: Int) -> UInt32 { Self.word(data, at, length) }
        guard let end = stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1).first(where: { word($0, 4) == 0x06054b50 && $0 + 22 + Int(word($0 + 20, 2)) == data.count }),
              word(end + 4, 2) == 0, word(end + 6, 2) == 0, word(end + 8, 2) == word(end + 10, 2),
              (1...2048).contains(Int(word(end + 10, 2))) else { throw AIFileDocumentText.Failure.unsupported }
        let count = Int(word(end + 10, 2)), central = Int(word(end + 16, 4)), centralSize = Int(word(end + 12, 4))
        guard centralSize <= 1_048_576, central + centralSize == end else { throw AIFileDocumentText.Failure.tooLarge }
        var position = central, total = 0, ranges: [Range<Int>] = []
        for _ in 0..<count {
            try check()
            guard position + 46 <= end, word(position, 4) == 0x02014b50 else { throw AIFileDocumentText.Failure.unsupported }
            let flags = Int(word(position + 8, 2)), method = Int(word(position + 10, 2)), size = Int(word(position + 20, 4)), plain = Int(word(position + 24, 4))
            let nameSize = Int(word(position + 28, 2)), extra = Int(word(position + 30, 2)), comment = Int(word(position + 32, 2)), offset = Int(word(position + 42, 4))
            guard flags & 0x2041 == 0, [0, 8].contains(method), word(position + 34, 2) == 0,
                  position + 46 + nameSize + extra + comment <= end, size <= 8_388_608, plain <= 8_388_608 else { throw AIFileDocumentText.Failure.unsupported }
            let rawName = data.subdata(in: position + 46..<position + 46 + nameSize)
            guard let name = String(data: rawName, encoding: .utf8), !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"),
                  !name.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }), entries[name] == nil else { throw AIFileDocumentText.Failure.unsupported }
            total += plain; guard total <= 33_554_432 else { throw AIFileDocumentText.Failure.tooLarge }
            guard offset + 30 <= central, word(offset, 4) == 0x04034b50,
                  word(offset + 6, 2) == UInt32(flags), word(offset + 8, 2) == UInt32(method) else { throw AIFileDocumentText.Failure.unsupported }
            if flags & 8 == 0 {
                guard word(offset + 14, 4) == word(position + 16, 4),
                      word(offset + 18, 4) == UInt32(size), word(offset + 22, 4) == UInt32(plain) else { throw AIFileDocumentText.Failure.unsupported }
            }
            let localNameSize = Int(word(offset + 26, 2)), localExtra = Int(word(offset + 28, 2)), payload = offset + 30 + localNameSize + localExtra
            guard payload + size <= central, data.subdata(in: offset + 30..<offset + 30 + localNameSize) == rawName else { throw AIFileDocumentText.Failure.unsupported }
            entries[name] = Entry(offset: payload, size: size, plain: plain, method: method, crc: word(position + 16, 4))
            ranges.append(offset..<payload + size)
            position += 46 + nameSize + extra + comment
        }
        guard position == end else { throw AIFileDocumentText.Failure.unsupported }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for pair in zip(sorted, sorted.dropFirst()) where pair.0.upperBound > pair.1.lowerBound { throw AIFileDocumentText.Failure.unsupported }
    }
    mutating func read(_ name: String, check: () throws -> Void) throws -> Data {
        guard let entry = entries[name], entry.plain <= 4_194_304 else { throw AIFileDocumentText.Failure.tooLarge }
        extracted += entry.plain; guard extracted <= 33_554_432 else { throw AIFileDocumentText.Failure.tooLarge }
        try check()
        let input = data.subdata(in: entry.offset..<entry.offset + entry.size)
        let output: Data
        if entry.method == 0 { output = input }
        else {
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw AIFileDocumentText.Failure.unsupported }
            defer { inflateEnd(&stream) }
            output = try input.withUnsafeBytes { source in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress); stream.avail_in = uInt(input.count)
                var result = Data(), status: Int32 = Z_OK
                repeat {
                    try check()
                    var buffer = [UInt8](repeating: 0, count: 32_768)
                    let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                        stream.next_out = bytes.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(bytes.count)
                        status = inflate(&stream, Z_NO_FLUSH); return bytes.count - Int(stream.avail_out)
                    }
                    guard [Z_OK, Z_STREAM_END].contains(status), result.count + count <= entry.plain, count > 0 || status == Z_STREAM_END else { throw AIFileDocumentText.Failure.unsupported }
                    result.append(contentsOf: buffer.prefix(count))
                } while status != Z_STREAM_END
                guard stream.total_in == input.count else { throw AIFileDocumentText.Failure.unsupported }
                return result
            }
        }
        let crc = output.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
        guard output.count == entry.plain, UInt32(crc) == entry.crc else { throw AIFileDocumentText.Failure.unsupported }
        return output
    }
    private static func word(_ data: Data, _ offset: Int, _ count: Int) -> UInt32 {
        guard offset >= 0, offset + count <= data.count else { return UInt32.max }
        return (0..<count).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
    }
}
