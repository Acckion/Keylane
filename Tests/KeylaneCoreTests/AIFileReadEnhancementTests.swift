import XCTest
import CoreGraphics
import CoreText
import PDFKit
import Vision
import zlib
@testable import KeylaneCore

final class AIFileReadEnhancementTests: XCTestCase {
    private let word = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private let sheet = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private let slide = "http://schemas.openxmlformats.org/presentationml/2006/main"
    private let rel = "http://schemas.openxmlformats.org/package/2006/relationships"
    private let rid = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private func docx(_ text: String, compressed: Bool = false) throws -> Data {
        try OfficeFixture.zip([("[Content_Types].xml", "<Types/>"), ("word/document.xml", "<w:document xmlns:w=\"\(word)\"><w:body><w:p><w:r><w:t>\(text)</w:t></w:r></w:p></w:body></w:document>")], compressed: compressed)
    }
    func testDOCXStoredAndDeflatedKeepParagraphsAndTables() throws {
        let body = "<w:document xmlns:w=\"\(word)\"><w:body><w:p><w:r><w:t>Hello 中文</w:t><w:tab/><w:t>World</w:t></w:r><w:del><w:r><w:t>deleted</w:t></w:r></w:del></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t><![CDATA[table <value>]]></w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>"
        for compressed in [false, true] {
            let data = try OfficeFixture.zip([("[Content_Types].xml", "<Types/>"), ("word/document.xml", body)], compressed: compressed)
            let text = try AIFileOfficeText.sections(data, extension: "docx").joined()
            XCTAssertTrue(text.contains("Hello 中文\tWorld\ntable <value>"))
            XCTAssertFalse(text.contains("deleted"))
        }
    }
    func testDOCXTextBoxParagraphsAreEmittedOnceWithinTextBudget() throws {
        let shape = "<w:pict><w:txbxContent><w:p><w:r><w:t>Text box contents</w:t></w:r></w:p></w:txbxContent></w:pict>"
        let alternate = "<mc:AlternateContent xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\"><mc:Choice Requires=\"w\">\(shape)</mc:Choice><mc:Fallback>\(shape)</mc:Fallback></mc:AlternateContent>"
        for content in [shape, alternate] {
            let body = "<w:document xmlns:w=\"\(word)\"><w:body><w:p><w:r><w:t>Before</w:t></w:r><w:r>\(content)</w:r><w:r><w:t>After</w:t></w:r></w:p></w:body></w:document>"
            let data = try OfficeFixture.zip([("[Content_Types].xml", "<Types/>"), ("word/document.xml", body)])
            let expected = "[Document]\nBeforeAfter\nText box contents\n"
            let text = try AIFileOfficeText.sections(data, extension: "docx", maximumTextBytes: expected.utf8.count).joined()
            XCTAssertEqual(text, expected)
            XCTAssertEqual(text.components(separatedBy: "Text box contents").count - 1, 1)
        }
    }

    func testWorkbookRelationshipsOrderRichStringsAndCachedValues() throws {
        let workbook = "<workbook xmlns=\"\(sheet)\" xmlns:r=\"\(rid)\"><sheets><sheet name=\"第二张\" sheetId=\"2\" r:id=\"r2\"/><sheet name=\"First\" sheetId=\"1\" r:id=\"r1\"/></sheets></workbook>"
        let relations = "<Relationships xmlns=\"\(rel)\"><Relationship Id=\"r1\" Type=\"\(rid)/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"r2\" Type=\"\(rid)/worksheet\" Target=\"/xl/worksheets/sheet2.xml\"/></Relationships>"
        let worksheet = "<worksheet xmlns=\"\(sheet)\"><sheetData><row><c r=\"A1\" t=\"s\"><v>0</v></c><c r=\"B1\"><f>HYPERLINK(\"https://fixture.invalid\")</f><v>42</v></c><c r=\"C1\" t=\"b\"><v>1</v></c><c r=\"D1\" t=\"inlineStr\"><is><t>inline</t></is></c><c r=\"E1\"><f>NEVER_EVALUATE()</f></c></row></sheetData></worksheet>"
        let data = try OfficeFixture.zip([("[Content_Types].xml", "<Types/>"), ("xl/workbook.xml", workbook.replacingOccurrences(of: "xmlns:r=", with: "xmlns:links=").replacingOccurrences(of: "r:id=", with: "links:id=")), ("xl/_rels/workbook.xml.rels", relations),
            ("xl/sharedStrings.xml", "<sst xmlns=\"\(sheet)\"><si><r><t>Alpha </t></r><r><t>β</t></r></si></sst>"), ("xl/worksheets/sheet1.xml", worksheet), ("xl/worksheets/sheet2.xml", worksheet)], compressed: true)
        let sections = try AIFileOfficeText.sections(data, extension: "xlsx")
        XCTAssertEqual(sections.count, 2); XCTAssertTrue(sections[0].hasPrefix("[Sheet: 第二张]"))
        XCTAssertTrue(sections[0].contains("A1\tAlpha β\nB1\t42\nC1\tTRUE\nD1\tinline\nE1\t[formula: no cached value]"))
        XCTAssertFalse(sections.joined().contains("fixture.invalid")); XCTAssertFalse(sections.joined().contains("NEVER_EVALUATE"))
    }
    func testSlidesFollowPresentationOrder() throws {
        let p = "<p:presentation xmlns:p=\"\(slide)\" xmlns:r=\"\(rid)\"><p:sldIdLst><p:sldId id=\"2\" r:id=\"b\"/><p:sldId id=\"1\" r:id=\"a\"/></p:sldIdLst></p:presentation>"
        let r = "<Relationships xmlns=\"\(rel)\"><Relationship Id=\"a\" Type=\"\(rid)/slide\" Target=\"slides/slide1.xml\"/><Relationship Id=\"b\" Type=\"\(rid)/slide\" Target=\"slides/slide2.xml\"/></Relationships>"
        func content(_ text: String) -> String { "<p:sld xmlns:p=\"\(slide)\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>\(text)</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>" }
        let data = try OfficeFixture.zip([("[Content_Types].xml", "<Types/>"), ("ppt/presentation.xml", p), ("ppt/_rels/presentation.xml.rels", r), ("ppt/slides/slide1.xml", content("first")), ("ppt/slides/slide2.xml", content("second"))])
        let sections = try AIFileOfficeText.sections(data, extension: "pptx")
        XCTAssertEqual(sections, ["[Slide 1]\nsecond\n", "[Slide 2]\nfirst\n"])
    }
    func testOfficeRejectsDTDExternalTargetsAndMalformedArchives() throws {
        let evil = try docx("<!DOCTYPE fake [<!ENTITY x SYSTEM 'file:///never-open'>]>&x;")
        XCTAssertThrowsError(try AIFileOfficeText.sections(evil, extension: "docx"))
        let external = try OfficeFixture.zip([("[Content_Types].xml", "<Types/>"),
            ("xl/workbook.xml", "<workbook xmlns=\"\(sheet)\" xmlns:r=\"\(rid)\"><sheets><sheet r:id=\"x\"/></sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", "<Relationships xmlns=\"\(rel)\"><Relationship Id=\"x\" Type=\"\(rid)/worksheet\" Target=\"https://never-fetch.invalid/test.xml\" TargetMode=\"External\"/></Relationships>")])
        XCTAssertThrowsError(try AIFileOfficeText.sections(external, extension: "xlsx"))
        XCTAssertThrowsError(try AIFileOfficeText.sections(Data("not zip".utf8), extension: "docx"))
        let valid = try docx("fixture")
        XCTAssertThrowsError(try AIFileOfficeText.sections(valid.dropLast(), extension: "docx"))
        XCTAssertThrowsError(try AIFileOfficeText.sections(valid, extension: "doc"))
        XCTAssertThrowsError(try AIFileOfficeText.sections(OfficeFixture.zip([("../word/document.xml", "no")]), extension: "docx"))
        XCTAssertThrowsError(try AIFileOfficeText.sections(OfficeFixture.zip([("same", "1"), ("same", "2")]), extension: "docx"))
        var badCRC = valid; badCRC[30 + "[Content_Types].xml".utf8.count + "<Types/>".utf8.count + 30 + "word/document.xml".utf8.count + 1] ^= 1
        XCTAssertThrowsError(try AIFileOfficeText.sections(badCRC, extension: "docx"))
    }
    func testOfficeTextXMLAndInflationLimitsAndCancellation() throws {
        XCTAssertThrowsError(try AIFileOfficeText.sections(docx(String(repeating: "x", count: 300)), extension: "docx", maximumTextBytes: 50))
        var encrypted = try docx("fixture"); encrypted[6] = 1
        XCTAssertThrowsError(try AIFileOfficeText.sections(encrypted, extension: "docx"))
        let nested = String(repeating: "<w:r>", count: 140) + "<w:t>text</w:t>" + String(repeating: "</w:r>", count: 140)
        let data = try OfficeFixture.zip([("[Content_Types].xml", "<Types/>"), ("word/document.xml", "<w:document xmlns:w=\"\(word)\"><w:body>\(nested)</w:body></w:document>")])
        XCTAssertThrowsError(try AIFileOfficeText.sections(data, extension: "docx"))
        let valid = try docx("fixture", compressed: true)
        XCTAssertThrowsError(try AIFileOfficeText.sections(valid, extension: "docx", check: { throw CancellationError() }))
    }
    func testOfficeSlicesAndInflatedSizeForgery() throws {
        let valid = try docx("slice fixture", compressed: true)
        let prefixed = Data([0, 1, 2]) + valid
        XCTAssertTrue(try AIFileOfficeText.sections(prefixed.dropFirst(3), extension: "docx").joined().contains("slice fixture"))
        // Selected XML larger than the parser budget, despite a tiny compressed ZIP.
        let oversized = try docx(String(repeating: "x", count: 4_194_305), compressed: true)
        XCTAssertThrowsError(try AIFileOfficeText.sections(oversized, extension: "docx"))
        // Central directory underreports the actual inflated XML size.
        var forged = try docx(String(repeating: "x", count: 10_000), compressed: true)
        let signature = Data([0x50, 0x4b, 0x01, 0x02])
        let first = try XCTUnwrap(forged.range(of: signature))
        let second = try XCTUnwrap(forged.range(of: signature, in: first.upperBound..<forged.endIndex))
        let localOffset = (0..<4).reduce(0) { $0 | Int(forged[second.lowerBound + 42 + $1]) << ($1 * 8) }
        forged.replaceSubrange(localOffset + 22..<localOffset + 26, with: [10, 0, 0, 0])
        forged.replaceSubrange(second.lowerBound + 24..<second.lowerBound + 28, with: [10, 0, 0, 0])
        XCTAssertThrowsError(try AIFileOfficeText.sections(forged, extension: "docx"))
    }
    func testOfficeReadUsesExistingPagedCursorAndVersionChecks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeylaneOfficeTool-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.docx"), data = try docx(String(repeating: "中文 body ", count: 100))
        try data.write(to: file)
        let service = AIFileToolService(), lease = AIFileAccessLease(), session = AIFileToolService.ReadSession(), scopes = [AIFileToolScope(path: root.path)]
        func call(_ name: String, _ args: [String: AIToolValue]) async throws -> [String: AIToolValue] {
            let plan = try await service.prepare("keylane_" + name, arguments: args, scopes: scopes, lease: lease, session: session)
            let result = try await service.execute(plan, lease: lease, cancellation: .init(), session: session)
            return try JSONDecoder().decode([String: AIToolValue].self, from: Data(result.text.utf8))
        }
        var page = try await call("read_file", ["path": .string("fixture.docx"), "limit": .number(40)])
        XCTAssertEqual(page["format"], .string("docx")); XCTAssertEqual(page["section_count"], .number(1))
        func text(_ value: AIToolValue?) -> String { if case .string(let text) = value { return text }; return "" }
        var result = text(page["text"])
        while let cursor = page["cursor"], cursor != .null {
            page = try await call("read_result", ["cursor": cursor, "limit": .number(40)]); result += text(page["text"])
        }
        XCTAssertEqual(result, try AIFileOfficeText.sections(data, extension: "docx").joined(separator: "\n\n"))
        do { _ = try await call("read_file", ["path": .string("fixture.docx"), "page": .number(1)]); XCTFail("PDF-only page accepted for Office") }
        catch { XCTAssertEqual(error as? AIFileToolError, .invalidPath) }
        let stale = try await call("read_file", ["path": .string("fixture.docx"), "limit": .number(40)])
        try docx("replacement").write(to: file)
        do { _ = try await call("read_result", ["cursor": try XCTUnwrap(stale["cursor"])]); XCTFail("Read stale Office data") }
        catch { XCTAssertEqual(error as? AIFileToolError, .stale) }
    }
    func testRegexModesAndAdversarialBacktrackingAreBounded() throws {
        XCTAssertTrue(try AIFileTextMatcher(query: "foo.*", regex: false, caseSensitive: false).contains("FOO.*", check: {}))
        XCTAssertFalse(try AIFileTextMatcher(query: "foo.*", regex: false, caseSensitive: false).contains("FOOBAR", check: {}))
        XCTAssertTrue(try AIFileTextMatcher(query: "^foo[0-9]+$", regex: true, caseSensitive: false).contains("FOO123", check: {}))
        XCTAssertFalse(try AIFileTextMatcher(query: "^foo[0-9]+$", regex: true, caseSensitive: true).contains("FOO123", check: {}))
        XCTAssertThrowsError(try AIFileTextMatcher(query: "[", regex: true, caseSensitive: false))
        let expensive = try AIFileTextMatcher(query: "(a+)+$", regex: true, caseSensitive: false, budget: 0.02)
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try expensive.contains(String(repeating: "a", count: 30_000) + "!", check: {}))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        let cancelled = try AIFileTextMatcher(query: "x", regex: true, caseSensitive: false)
        XCTAssertThrowsError(try cancelled.contains("x", check: { throw CancellationError() }))
    }
    func testGrepRegexUsesSameCRLFLineNumbersAndPaging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeylaneRegexTool-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); defer { try? FileManager.default.removeItem(at: root) }
        try Data("foo.*\r\nFOO12\r\nfoo34\nother".utf8).write(to: root.appendingPathComponent("fixture"))
        let service = AIFileToolService(), lease = AIFileAccessLease(), session = AIFileToolService.ReadSession()
        let plan = try await service.prepare("keylane_grep", arguments: ["path": .string("."), "pattern": .string("**/*"), "query": .string("^foo[0-9]+$"), "regex": .bool(true), "limit": .number(1)], scopes: [.init(path: root.path)], lease: lease, session: session)
        let result = try await service.execute(plan, lease: lease, cancellation: .init(), session: session)
        let page = try JSONDecoder().decode([String: AIToolValue].self, from: Data(result.text.utf8))
        guard case .array(let rows) = page["matches"], case .object(let match) = rows.first else { return XCTFail("Missing regex match") }
        XCTAssertEqual(match["line"], .number(2)); XCTAssertNotNil(page["cursor"])
    }
    func testScannedPDFRequiresExplicitOCRAndUsesLocalEngine() throws {
        try warmNativeOCR()
        let data = Self.scannedPDF("KEYLANE OCR FIXTURE 12345")
        XCTAssertThrowsError(try AIFileDocumentText.pdfPages(data))
        let text = try AIFileDocumentText.pdfPages(data, ocr: true).joined()
        XCTAssertTrue(text.contains("KEYLANE")); XCTAssertTrue(text.contains("12345"))
        let work = ImageTextRecognitionWork(); work.cancel()
        XCTAssertThrowsError(try AIFileDocumentText.pdfPages(data, ocr: true, work: work)) { XCTAssertTrue($0 is CancellationError) }
    }
    func testOCRServiceResultRetainsModeAcrossPagesAndRejectsOtherTypes() async throws {
        try warmNativeOCR()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeylaneOCRTool-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); defer { try? FileManager.default.removeItem(at: root) }
        try Self.scannedPDF("KEYLANE OCR FIXTURE 12345").write(to: root.appendingPathComponent("scan.pdf"))
        try Data("text".utf8).write(to: root.appendingPathComponent("text"))
        let service = AIFileToolService(), lease = AIFileAccessLease(), session = AIFileToolService.ReadSession()
        let plan = try await service.prepare("keylane_read_file", arguments: ["path": .string("scan.pdf"), "ocr": .bool(true), "limit": .number(10)], scopes: [.init(path: root.path)], lease: lease, session: session)
        let output = try await service.execute(plan, lease: lease, cancellation: .init(), session: session)
        let value = try JSONDecoder().decode([String: AIToolValue].self, from: Data(output.text.utf8))
        XCTAssertEqual(value["ocr"], .bool(true)); XCTAssertEqual(value["format"], .string("pdf")); XCTAssertNotNil(value["cursor"])
        let continuation = try await service.prepare("keylane_read_result", arguments: ["cursor": try XCTUnwrap(value["cursor"]), "limit": .number(10)], scopes: [.init(path: root.path)], lease: lease, session: session)
        let cancelledOCR = ImageTextRecognitionWork(); cancelledOCR.cancel()
        let continued = try await service.execute(continuation, lease: lease, cancellation: .init(), session: session, documentWork: cancelledOCR)
        let next = try JSONDecoder().decode([String: AIToolValue].self, from: Data(continued.text.utf8))
        XCTAssertEqual(next["ocr"], .bool(true)); XCTAssertEqual(next["offset"], .number(10))
        let textPlan = try await service.prepare("keylane_read_file", arguments: ["path": .string("text"), "ocr": .bool(true)], scopes: [.init(path: root.path)], lease: lease, session: session)
        do { _ = try await service.execute(textPlan, lease: lease, cancellation: .init(), session: session); XCTFail("OCR on non-PDF") }
        catch { XCTAssertEqual(error as? AIFileToolError, .unsupported) }
    }
    // Verify the native engine separately from the bounded PDF operation. Apple
    // may initialize its recognition assets on the first request; PDF deadlines
    // intentionally remain enforced and can reject a cold request.
    private func warmNativeOCR() throws {
        let text = try LocalImageTextRecognition.ocr.recognize(in: VNImageRequestHandler(cgImage: Self.scannedImage("KEYLANE 12345")), accurate: true)
        XCTAssertTrue(text.contains("KEYLANE")); XCTAssertTrue(text.contains("12345"))
    }
    static func scannedImage(_ text: String) -> CGImage {
        let image = CGContext(data: nil, width: 1400, height: 300, bitsPerComponent: 8, bytesPerRow: 5600, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        image.setFillColor(CGColor(gray: 1, alpha: 1)); image.fill(CGRect(x: 0, y: 0, width: 1400, height: 300))
        image.textPosition = CGPoint(x: 50, y: 140)
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 65, nil), NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
        CTLineDraw(CTLineCreateWithAttributedString(string), image)
        return image.makeImage()!
    }
    static func scannedPDF(_ text: String) -> Data {
        let data = NSMutableData() // Image-only PDF; no searchable text layer.
        let target = CGDataConsumer(data: data as CFMutableData)!
        var box = CGRect(x: 0, y: 0, width: 700, height: 150)
        let pdf = CGContext(consumer: target, mediaBox: &box, nil)!
        pdf.beginPDFPage(nil); pdf.draw(scannedImage(text), in: box); pdf.endPDFPage(); pdf.closePDF()
        return data as Data
    }
}

private enum OfficeFixture {
    static func zip(_ parts: [(String, String)], compressed: Bool = false) throws -> Data {
        var body = Data(), directory = Data()
        func word(_ value: Int, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        for (name, text) in parts {
            let raw = Data(text.utf8), name = Data(name.utf8), offset = body.count
            let crc = raw.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            let payload: Data
            if compressed {
                var stream = z_stream()
                guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw AIFileDocumentText.Failure.unsupported }
                defer { deflateEnd(&stream) }
                payload = raw.withUnsafeBytes { input in
                    stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress); stream.avail_in = uInt(raw.count)
                    var buffer = [UInt8](repeating: 0, count: raw.count + 1024)
                    let count = buffer.withUnsafeMutableBytes { out -> Int in
                        stream.next_out = out.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(out.count)
                        _ = deflate(&stream, Z_FINISH); return out.count - Int(stream.avail_out)
                    }
                    return Data(buffer.prefix(count))
                }
            } else { payload = raw }
            for (value, width) in [(0x04034b50,4),(20,2),(0,2),(compressed ? 8 : 0,2),(0,4),(Int(crc),4),(payload.count,4),(raw.count,4),(name.count,2),(0,2)] { body += word(value, width) }
            body += name; body += payload
            for (value, width) in [(0x02014b50,4),(20,2),(20,2),(0,2),(compressed ? 8 : 0,2),(0,4),(Int(crc),4),(payload.count,4),(raw.count,4),(name.count,2),(0,2),(0,2),(0,2),(0,2),(0,4),(offset,4)] { directory += word(value, width) }
            directory += name
        }
        var result = body + directory
        for (value, width) in [(0x06054b50,4),(0,2),(0,2),(parts.count,2),(parts.count,2),(directory.count,4),(body.count,4),(0,2)] { result += word(value, width) }
        return result
    }
}
