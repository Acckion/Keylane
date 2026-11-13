import Foundation
import AppKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import KeylaneCore

final class PreviewFixtureProtocol: URLProtocol {
    static let lock = NSLock()
    static var requests = 0
    static var cancellations = 0
    static let icon = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aHv8AAAAASUVORK5CYII=")!

    static func counts() -> (requests: Int, cancellations: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (requests, cancellations)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".example") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        Self.lock.unlock()
        guard let url = request.url, url.host != "delayed.example" else { return }
        let headers = ["Content-Type": "image/png", "Content-Length": String(Self.icon.count)]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.icon)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        guard request.url?.host == "delayed.example" else { return }
        Self.lock.lock()
        Self.cancellations += 1
        Self.lock.unlock()
    }
}

let app = NSApplication.shared
let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEYLANE_CLIPBOARD_TEST_ROOT"]!).appendingPathComponent("fixtures")
let suite = "org.keylane.clipboard.test." + UUID().uuidString
let prefs = UserDefaults(suiteName: suite)!
let board = NSPasteboard(name: .init(suite))
let controller = ClipboardController(directory: root, board: board, preferences: prefs, startTimer: false)
func wait(_ message: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(message == "Vision OCR" ? 50 : 12)
    while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
    if !condition() { fputs("FAIL total=\(controller.total) list=\(controller.items.count) detail=\(controller.detail != nil) status=\(controller.status) root=\(root.path)\n", stderr) }; precondition(condition(), message + " status=" + controller.status)
}
func write(_ text: String) { board.clearContents(); board.setString(text, forType: .string); controller.poll() }
defer { board.releaseGlobally(); prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
var previewTestFinished = false
Task { @MainActor in
    let previews = ClipboardLinkPreviews {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PreviewFixtureProtocol.self]
        return URLSession(configuration: config)
    }
    let url = URL(string: "https://favicon.example/clip")!
    let disabledIcon = await previews.icon(for: url)
    let disabledPage = await previews.preview(for: url)
    precondition(disabledIcon == nil && disabledPage == nil && PreviewFixtureProtocol.counts().requests == 0)
    previews.setEnabled(true)
    let enabledIcon = await previews.icon(for: url)
    precondition(enabledIcon != nil && PreviewFixtureProtocol.counts().requests == 1)
    let delayed = URL(string: "https://delayed.example/clip")!
    let task = Task { await previews.icon(for: delayed) }
    for _ in 0..<100 {
        if PreviewFixtureProtocol.counts().requests == 2 { break }
        try? await Task.sleep(for: .milliseconds(10))
    }
    precondition(PreviewFixtureProtocol.counts().requests == 2)
    previews.setEnabled(false)
    let cancelledIcon = await task.value
    let cachedIcon = await previews.icon(for: url)
    let disabledAgain = await previews.preview(for: delayed)
    precondition(cancelledIcon == nil && cachedIcon == nil && disabledAgain == nil)
    precondition(PreviewFixtureProtocol.counts().requests == 2 && PreviewFixtureProtocol.counts().cancellations == 1)
    previews.setEnabled(true)
    let reenabledIcon = await previews.icon(for: url)
    precondition(reenabledIcon != nil && PreviewFixtureProtocol.counts().requests == 3)
    previews.setEnabled(false)
    previewTestFinished = true
}
wait("preview opt-out stops and cancels requests") { previewTestFinished }
print("PASS link preview opt-out, in-flight cancellation and re-enable")
write("MUST NOT CAPTURE")
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
precondition(controller.total == 0)
controller.captureEnabled = true
write("Keylane 中文 clipboard probe")
wait("capture text") { controller.total == 1 && controller.detail?.text == "Keylane 中文 clipboard probe" }
controller.pinSelected(); wait("pin") { controller.detail?.item.pinned == true }
write("Second record")
wait("second") { controller.total == 2 }
write("Keylane 中文 clipboard probe")
wait("dedup and stable pin") { controller.items.first?.copyCount == 2 && controller.total == 2 }
precondition(controller.copySelected())
precondition(board.string(forType: .string) == "Keylane 中文 clipboard probe")
controller.poll()
RunLoop.current.run(until: Date().addingTimeInterval(0.1))
precondition(controller.items.first?.copyCount == 2)
// Sensitive marker must skip before content is read.
board.clearContents(); board.setString("DO NOT SAVE", forType: .string); board.setString("1", forType: .init("org.nspasteboard.ConcealedType")); controller.poll()
RunLoop.current.run(until: Date().addingTimeInterval(0.1)); precondition(controller.total == 2)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 256, height: 100).fill()
("KEYLANE OCR 123" as NSString).draw(at: NSPoint(x: 8, y: 35), withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
NSGraphicsContext.restoreGraphicsState()
let png = bitmap.representation(using: .png, properties: [:])!
board.clearContents(); board.setData(png, forType: .png); controller.poll()
wait("image capture") { controller.total == 3 }
let image = controller.items.first { $0.kind == .image }!; controller.select(image.id)
wait("thumbnail") { controller.thumbnail != nil }
var listImage: NSImage?
controller.loadListThumbnail(for:image) { listImage = $0 }
wait("small list thumbnail") { listImage != nil }
let smallCG = listImage!.cgImage(forProposedRect:nil,context:nil,hints:nil)!
precondition(max(smallCG.width,smallCG.height) <= 64)
var cachedImage: NSImage?
controller.loadListThumbnail(for:image) { cachedImage = $0 }
wait("cached list thumbnail") { cachedImage != nil }
precondition(listImage === cachedImage)
var cancelledThumbnailFinished = false
let cancelledThumbnail = Task { @MainActor in
    let result = await controller.listThumbnail(for: image)
    precondition(result == nil)
    cancelledThumbnailFinished = true
}
cancelledThumbnail.cancel()
wait("cancelled row thumbnail completes without publishing") { cancelledThumbnailFinished }
// A fresh controller must recover from the saved representations if the owned cache is lost.
let imageAsset = (try! ClipboardStore(directory:root).detail(id:image.id))!.assetURL!
let movedAsset = imageAsset.appendingPathExtension("fixture-backup")
try FileManager.default.moveItem(at:imageAsset,to:movedAsset)
let fallbackController = ClipboardController(directory:root,board:board,preferences:prefs,startTimer:false)
var fallbackImage: NSImage?
fallbackController.loadListThumbnail(for:image) { fallbackImage = $0 }
wait("list thumbnail snapshot fallback") { fallbackImage != nil }
try FileManager.default.moveItem(at:movedAsset,to:imageAsset)

controller.search("OCR 123")
wait("Vision OCR") { controller.items.map(\.id) == [image.id] && controller.detail?.ocrText.contains("KEYLANE") == true }
precondition(controller.copySelected()); precondition(board.data(forType: .png) == png)
controller.search(""); wait("reset") { controller.items.count == 3 }
let textItem = controller.items.first { $0.kind == .text }!
for _ in 0..<24 { controller.select(image.id); controller.select(textItem.id) }
wait("rapid selection keeps latest detail") { controller.detail?.item.id == textItem.id && !controller.loadingDetail }
precondition(controller.thumbnail == nil)
controller.select(image.id)
controller.endPresentation()
RunLoop.current.run(until: Date().addingTimeInterval(0.15))
precondition(controller.detail == nil && controller.thumbnail == nil && !controller.loadingDetail)
controller.search("")
wait("reopen after cancelling an in-flight preview") { controller.detail?.item.id == image.id && controller.thumbnail != nil }
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let file = root.appendingPathComponent("fixture.txt"); try Data("OWN FIXTURE".utf8).write(to: file)
board.clearContents(); board.writeObjects([file as NSURL]); controller.poll()
wait("file capture") { controller.total == 4 }
let fileID = controller.items.first { $0.kind == .files }!.id; controller.select(fileID)
wait("file detail") { controller.detail?.item.id == fileID }
precondition(controller.copySelected())
let copiedFile = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first
precondition(copiedFile?.resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
controller.removeSelected(); wait("file history deletion") { controller.total == 3 }
precondition(FileManager.default.fileExists(atPath: file.path))
let reopened = try ClipboardStore(directory: root)
let reopenedCount = try reopened.count(); precondition(reopenedCount == 3)
controller.clear(includePinned: false); wait("clear unpinned") { controller.total == 1 }
precondition(controller.items.first?.pinned == true)
controller.clear(includePinned: true); wait("clear all") { controller.total == 0 }
controller.endPresentation()
write("Captured with the page closed")
wait("background capture without preview") { controller.total == 1 }
precondition(controller.detail == nil && controller.thumbnail == nil && !controller.loadingDetail)
controller.search("Captured with the page closed")
wait("reopen after background capture") { controller.detail?.text == "Captured with the page closed" }
controller.clear(includePinned: true); wait("clear closed-page fixture") { controller.total == 0 }
controller.search(""); wait("reset closed-page fixture query") { !controller.searching }
let richString = "富文本格式示例"
let attributed = NSAttributedString(string:richString,attributes:[.font:NSFont.boldSystemFont(ofSize:18)])
let rtf = try attributed.data(from:NSRange(location:0,length:attributed.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])
let html = Data("<b>富文本格式示例</b>".utf8)
let rich = NSPasteboardItem(); rich.setString(richString,forType:.string); rich.setData(rtf,forType:.rtf); rich.setData(html,forType:.html)
board.clearContents(); board.writeObjects([rich]); controller.poll()
wait("rich capture") { controller.total == 1 && controller.detail?.snapshot?.hasRichText == true }
let richID = controller.selectedID!
let heldDetail = controller.detail
var detailDisappeared = false
let observation = controller.$detail.dropFirst().sink { if $0 == nil { detailDisappeared = true } }
controller.reload(); RunLoop.current.run(until:Date().addingTimeInterval(0.15))
precondition(!detailDisappeared && controller.detail?.item.id == heldDetail?.item.id)
observation.cancel()
precondition(controller.copySelected())
precondition(board.data(forType:.rtf) == rtf && board.data(forType:.html) == html)
precondition(controller.copySelected(plainText:true))
precondition(board.string(forType:.string) == richString && board.data(forType:.rtf) == nil && board.data(forType:.html) == nil)
precondition(controller.availableReplayFormats.contains(.representation("public.rtf")))
precondition(controller.availableReplayFormats.contains(.representation("public.html")))
precondition(controller.copySelected(format: .representation("public.rtf")))
precondition(board.data(forType: .rtf) == rtf && board.data(forType: .html) == nil)
precondition(controller.copySelected(format: .representation("public.html")))
precondition(board.data(forType: .html) == html && board.data(forType: .rtf) == nil)
controller.prefersPlainText = true
precondition(controller.copySelected(format: .preferred))
precondition(board.string(forType: .string) == richString && board.data(forType: .rtf) == nil)
precondition(controller.copySelected(format: .original))
precondition(board.data(forType: .rtf) == rtf && board.data(forType: .html) == html)
let firstItem = NSPasteboardItem(); firstItem.setString("多个项目里的文字",forType:.string)
let secondItem = NSPasteboardItem(); secondItem.setData(png,forType:.png)
board.clearContents(); board.writeObjects([firstItem,secondItem]); controller.poll()
wait("multiple representations") { controller.total == 2 }
let mixedID = controller.items.first { $0.id != richID }!.id
controller.select(mixedID); wait("mixed detail") { controller.detail?.item.id == mixedID && !controller.loadingDetail }
precondition(controller.detail?.snapshot?.items.count == 2)
let beforeInvalidSelection = board.changeCount
precondition(!controller.copySelected(format: .representation("public.png")))
precondition(board.changeCount == beforeInvalidSelection)
precondition(controller.copySelected(format: .preferred))
precondition(board.pasteboardItems?.count == 2)
precondition(board.pasteboardItems?.first?.string(forType:.string) == "多个项目里的文字")
precondition(board.pasteboardItems?.last?.data(forType:.png) == png)
let restored = try ClipboardStore(directory:root)
precondition(try! restored.detail(id:richID)?.snapshot?.hasRichText == true)
let htmlOnly = NSPasteboardItem(); htmlOnly.setData(Data("<p>猫&amp;狗</p><img src='https://invalid.example/never-load.png'><script>never-run()</script>".utf8),forType:.html)
board.clearContents(); board.writeObjects([htmlOnly]); controller.poll()
wait("inert HTML projection") { controller.total == 3 }
controller.search("猫&狗"); wait("HTML text search") { controller.items.count == 1 && controller.detail?.snapshot?.plainText == "猫&狗" }
precondition(controller.copySelected(plainText:true)); precondition(board.string(forType:.string) == "猫&狗")
controller.search(""); wait("unfiltered replay list") { controller.items.count == 3 && !controller.searching }
controller.select(richID); wait("old selection ready") { controller.selectedDetail?.item.id == richID }
controller.recordReplay(of: richID)
let firstBeforeReplay = try ClipboardStore(directory: root).list().first?.id
precondition(firstBeforeReplay != richID)
controller.updatesHistoryAfterReplay = true
controller.recordReplay(of: richID)
wait("replay moves old row to top") { controller.items.first?.id == richID }
precondition(controller.items.first?.copyCount == 1)
let tiff = bitmap.representation(using: .tiff, properties: [:])!
let tiffItem = NSPasteboardItem()
tiffItem.setData(tiff, forType: .tiff)
board.clearContents(); board.writeObjects([tiffItem]); controller.poll()
wait("TIFF capture") { controller.items.contains { $0.assetName?.hasSuffix(".tiff") == true } }
let tiffID = controller.items.first { $0.assetName?.hasSuffix(".tiff") == true }!.id
controller.select(tiffID)
wait("TIFF detail") { !controller.loadingDetail && controller.selectedDetail?.item.id == tiffID }
precondition(controller.availableReplayFormats.contains(.pngFromTIFF))
precondition(controller.copySelected(format: .pngFromTIFF))
let converted = NSBitmapImageRep(data: board.data(forType: .png)!)
precondition(converted?.pixelsWide == bitmap.pixelsWide && converted?.pixelsHigh == bitmap.pixelsHigh)
precondition(board.pasteboardItems?.first?.types.contains(.tiff) == false)
controller.primaryAction = .copy
controller.showsLinkVisuals = false
let reloadedPreferences = ClipboardController(directory: root, board: board, preferences: prefs, startTimer: false, startStorage: false)
precondition(reloadedPreferences.primaryAction == .copy && reloadedPreferences.prefersPlainText)
precondition(reloadedPreferences.updatesHistoryAfterReplay && !reloadedPreferences.showsLinkVisuals)
print("PASS selected RTF/HTML, TIFF-to-PNG, mixed payload, replay order and persisted preferences")
controller.clear(includePinned:true); wait("cleanup final") { controller.total == 0 }
// Format-only captures use display labels in the database, not in their pasteboard payload.
let rtfd = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
let pdfData = NSMutableData()
let pdfConsumer = CGDataConsumer(data: pdfData as CFMutableData)!
var pdfBounds = CGRect(x: 0, y: 0, width: 100, height: 100)
let pdf = CGContext(consumer: pdfConsumer, mediaBox: &pdfBounds, nil)!
pdf.beginPDFPage(nil)
pdf.fill(pdfBounds)
pdf.endPDFPage()
pdf.closePDF()

for (type, data, label) in [(NSPasteboard.PasteboardType.rtfd, rtfd, "富文本内容"),
                            (.pdf, pdfData as Data, "PDF剪贴板内容")] {
    let item = NSPasteboardItem()
    item.setData(data, forType: type)
    board.clearContents()
    precondition(board.writeObjects([item]))
    controller.poll()
    controller.search(label)
    wait("format-only capture: " + label) {
        controller.selectedDetail?.text == label && controller.selectedDetail?.snapshot?.plainText == ""
    }
    precondition(controller.availableReplayFormats.contains(.representation(type.rawValue)))
    precondition(!controller.availableReplayFormats.contains(.plainText), "Display label offered as plain text: " + label)
    let originalChangeCount = board.changeCount
    precondition(!controller.copySelected(format: .plainText))
    precondition(board.changeCount == originalChangeCount)
    precondition(controller.copySelected(format: .preferred))
    precondition(board.pasteboardItems?.first?.data(forType: type) == data)
    precondition(board.pasteboardItems?.first?.types.contains(.string) == false)
}

let legacyText = "旧记录的真实纯文本"
let legacyID = try restored.capture(.text(legacyText))
controller.search(legacyText)
wait("legacy text without snapshot") { controller.selectedDetail?.item.id == legacyID }
precondition(controller.selectedDetail?.snapshot == nil && controller.availableReplayFormats.contains(.plainText))
precondition(controller.copySelected(format: .preferred))
precondition(board.string(forType: .string) == legacyText)
precondition(controller.copySelected(format: .plainText))
precondition(board.string(forType: .string) == legacyText)
controller.clear(includePinned: true)
wait("cleanup format-only fixtures") { controller.total == 0 }
print("PASS RTFD/PDF labels excluded from plain-text replay; source formats and legacy text preserved")

// Automatic monitor regression: no explicit poll calls, including while the app is inactive.
let automaticSuite = suite + ".automatic"
let automaticPrefs = UserDefaults(suiteName:automaticSuite)!
automaticPrefs.set(true,forKey:"clipboardPersistentCapture")
let automaticBoard = NSPasteboard(name:.init(automaticSuite))
let automaticRoot = root.appendingPathComponent("automatic")
let automatic = ClipboardController(directory: automaticRoot, board: automaticBoard, preferences: automaticPrefs)
defer { automaticBoard.releaseGlobally(); automaticPrefs.removePersistentDomain(forName:automaticSuite) }
automaticBoard.clearContents(); automaticBoard.setString("Automatic monitor 中文",forType:.string)
wait("automatic timer capture") { automatic.total == 1 && automatic.detail?.text == "Automatic monitor 中文" }
automaticBoard.clearContents(); automaticBoard.setString("Second automatic copy",forType:.string)
wait("second automatic timer capture") { automatic.total == 2 }
automaticBoard.clearContents(); automaticBoard.setData(png,forType:.png)
wait("automatic timer image capture") { automatic.total == 3 && automatic.items.contains { $0.kind == .image } }
automatic.kind = "text"
wait("header text filter") { automatic.items.count == 2 && automatic.items.allSatisfy { $0.kind == .text } }
automatic.kind = "image"
wait("header image filter") { automatic.items.count == 1 && automatic.detail?.item.kind == .image }
automaticBoard.clearContents(); automaticBoard.writeObjects([file as NSURL])
wait("automatic file capture while image filter active") { automatic.total == 4 }
automatic.kind = "files"
wait("header files filter") { automatic.items.count == 1 && automatic.detail?.item.kind == .files }
automatic.kind = "all"
wait("header all filter") { automatic.items.count == 4 }
let copiedImageFile = root.appendingPathComponent("thumbnail-file.png")
try png.write(to:copiedImageFile)
automaticBoard.clearContents(); automaticBoard.writeObjects([copiedImageFile as NSURL])
wait("automatic copied image file") { automatic.total == 5 }
let fileImageItem = automatic.items.first { $0.kind == .files && $0.preview.contains("thumbnail-file.png") }!
var fileThumbnail: NSImage?
automatic.loadListThumbnail(for:fileImageItem) { fileThumbnail = $0 }
wait("copied image file list thumbnail") { fileThumbnail != nil }
automatic.select(fileImageItem.id)
wait("copied image file detail preview") {
    automatic.detail?.item.id == fileImageItem.id && automatic.thumbnail != nil
}
let filePreview = automatic.thumbnail!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
precondition(filePreview.width == bitmap.pixelsWide && filePreview.height == bitmap.pixelsHigh)
precondition(FileManager.default.fileExists(atPath:copiedImageFile.path))

let originalColor = " #0c4cdd "
automaticBoard.clearContents()
automaticBoard.setString(originalColor, forType: .string)
wait("automatic color capture") { automatic.total == 6 }
automaticBoard.clearContents()
automaticBoard.setString("https://example.com/", forType: .URL)
wait("automatic link capture") { automatic.total == 7 }
automaticBoard.clearContents()
automaticBoard.setString("design@example.com", forType: .string)
wait("automatic email capture") { automatic.total == 8 }
for category: ClipboardCategory in [.link, .email, .color] {
    automatic.kind = category.rawValue
    wait("header \(category) filter") {
        automatic.items.count == 1 && automatic.detail?.item.category == category
    }
}
precondition(automatic.copySelected())
precondition(automaticBoard.string(forType: .string) == originalColor)
let color = automatic.detail!.item.color!
for format in ClipboardColor.Format.allCases {
    precondition(automatic.copyColor(color, as: format))
    precondition(automaticBoard.string(forType: .string) == color.formatted(as: format))
    automatic.poll()
}
automatic.kind = "all"
wait("converted colors were not recaptured") { automatic.items.count == 8 && automatic.total == 8 }

let originalText = automatic.items.first { $0.preview == "Second automatic copy" }!
automatic.select(originalText.id)
wait("selected text before edit") { automatic.selectedDetail?.item.id == originalText.id }
automatic.editSelectedText()
precondition(automatic.textDraft?.text == "Second automatic copy")
var edited = false
automatic.saveEditedText(id: originalText.id, text: "Edited 中文\nSecond line") { result in
    try! result.get()
    edited = true
}
wait("saved text remains selected") { edited && automatic.selectedDetail?.text == "Edited 中文\nSecond line" }
precondition(automatic.copySelected())
precondition(automaticBoard.string(forType: .string) == "Edited 中文\nSecond line")

let fileImageDetail = try ClipboardStore(directory: automaticRoot).detail(id: fileImageItem.id)!
var copiedOCR = false
automatic.copyImageText(.ocr, from: fileImageDetail) { copied, message in
    precondition(copied, message)
    copiedOCR = true
}
wait("Vision OCR") { copiedOCR }
precondition(automaticBoard.string(forType: .string)?.contains("KEYLANE") == true)

let qr = CIFilter.qrCodeGenerator()
qr.message = Data("https://example.com/clipboard-fixture".utf8)
let qrImage = qr.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
let qrCG = CIContext().createCGImage(qrImage, from: qrImage.extent)!
let qrData = NSBitmapImageRep(cgImage: qrCG).representation(using: .png, properties: [:])!
automaticBoard.clearContents()
automaticBoard.setData(qrData, forType: .png)
wait("capture QR image") { automatic.total == 9 && automatic.items.first?.kind == .image }
let qrID = automatic.items.first!.id
automatic.select(qrID)
wait("select QR image") { automatic.selectedDetail?.item.id == qrID }
let qrDetail = automatic.selectedDetail!
var copiedQR = false
automatic.copyImageText(.qr, from: qrDetail) { copied, message in
    precondition(copied, message)
    copiedQR = true
}
wait("copy QR payload") { copiedQR }
precondition(automaticBoard.string(forType: .string) == "https://example.com/clipboard-fixture")

// Historical raw images and Finder image copies must be searchable without a manual OCR action.
let searchRoot = root.appendingPathComponent("ocr-search")
let searchStore = try ClipboardStore(directory: searchRoot)
let searchBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 175,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: searchBitmap)
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: 900, height: 175).fill()
("剪贴板文字测试" as NSString).draw(at: NSPoint(x: 40, y: 50), withAttributes: [
    .font: NSFont(name: "PingFangSC-Semibold", size: 52) ?? NSFont.systemFont(ofSize: 52),
    .foregroundColor: NSColor.black
])
NSGraphicsContext.restoreGraphicsState()
let searchPNG = searchBitmap.representation(using: .png, properties: [:])!
let searchImageFile = root.appendingPathComponent("legacy-image.png")
try searchPNG.write(to: searchImageFile)
let rawID = try searchStore.capture(.image(searchPNG))
let imageFileID = try searchStore.capture(.files([.init(path: searchImageFile.path)]))
precondition(try! searchStore.list(query: "剪贴板文字测试").isEmpty)
let searchSuite = suite + ".ocr-search"
let searchPrefs = UserDefaults(suiteName: searchSuite)!
let searchBoard = NSPasteboard(name: .init(searchSuite))
let imageSearch = ClipboardController(directory: searchRoot, board: searchBoard, preferences: searchPrefs, startTimer: false)
defer { searchBoard.releaseGlobally(); searchPrefs.removePersistentDomain(forName: searchSuite) }
precondition(!imageSearch.automaticOCR)
imageSearch.search("剪贴板文字测试")
wait("Vision OCR") { Set(imageSearch.items.map(\.id)) == Set([rawID, imageFileID]) && !imageSearch.indexingImageText }
imageSearch.kind = "files"
wait("OCR file filter") { imageSearch.items.map(\.id) == [imageFileID] }
imageSearch.endPresentation()
precondition(try! searchStore.list(query: "剪贴板文字测试", category: .image).map(\.id) == [rawID])

let newImageFile = root.appendingPathComponent("background-image.png")
try searchPNG.write(to: newImageFile)
imageSearch.automaticOCR = true
imageSearch.captureEnabled = true
searchBoard.clearContents()
precondition(searchBoard.writeObjects([newImageFile as NSURL]))
imageSearch.poll()
wait("Vision OCR") { (try? searchStore.list(query: "剪贴板文字测试", category: .files).count) == 2 }

let savedCount = try searchStore.count()
imageSearch.stopRuntime()
precondition(imageSearch.captureEnabled && imageSearch.items.isEmpty && !imageSearch.indexingImageText)
searchBoard.clearContents()
searchBoard.setString("ignored while disabled", forType: .string)
imageSearch.poll()
RunLoop.current.run(until: Date().addingTimeInterval(0.5))
precondition(try! searchStore.count() == savedCount)
imageSearch.startRuntime()
imageSearch.startMonitoring()
imageSearch.kind = "all"
imageSearch.search("剪贴板文字测试")
wait("old clipboard data after restart") { imageSearch.items.contains { $0.id == rawID } }
searchBoard.clearContents()
searchBoard.setString("new entry after restart", forType: .string)
wait("automatic capture after restart") { (try? searchStore.count()) == savedCount + 1 }
imageSearch.stopRuntime()

// Reproduce a remote generation whose payload is delivered later without a new change count.
let universalSuite = suite + ".universal"
let universalPreferences = UserDefaults(suiteName: universalSuite)!
let universalBoard = NSPasteboard(name: .init(universalSuite))
let universalDirectory = root.appendingPathComponent("universal")
let universal = ClipboardController(directory: universalDirectory,
                                    board: universalBoard, preferences: universalPreferences, startTimer: false)
defer { universalBoard.releaseGlobally(); universalPreferences.removePersistentDomain(forName: universalSuite) }
let remoteType = NSPasteboard.PasteboardType(ClipboardCapture.remoteType)
universal.captureEnabled = true
precondition(!universal.savesUniversalClipboardImmediately)
universalBoard.clearContents()
precondition(universalBoard.setString("1", forType: remoteType))
precondition(universalBoard.setString("Disabled universal fixture", forType: .string))
universal.universalClipboardArrived(universalBoard.changeCount)
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
precondition(universal.total == 0)

universal.savesUniversalClipboardImmediately = true
precondition(universalPreferences.bool(forKey: "clipboardSaveUniversalImmediately"))
universalBoard.clearContents()
precondition(universalBoard.setString("1", forType: remoteType))
let remoteGeneration = universalBoard.changeCount
let logEvent = Data("{\"eventMessage\":\"Current generation after remote pasteboard change: \(remoteGeneration)\"}".utf8)
precondition(UniversalClipboardMonitor.generation(in: logEvent) == remoteGeneration)
precondition(UniversalClipboardMonitor.generation(in: Data("{\"count\":0,\"finished\":1}".utf8)) == nil)
universal.universalClipboardArrived(UniversalClipboardMonitor.generation(in: logEvent)!)
precondition(universal.total == 0)
precondition(universalBoard.setString("Delayed universal text 中文", forType: .string))
precondition(universalBoard.changeCount == remoteGeneration)
wait("same-generation universal retry") {
    universal.poll()
    return universal.total == 1 && universal.detail?.text == "Delayed universal text 中文"
}
precondition(universal.detail?.item.source == "通用剪贴板")
universal.universalClipboardArrived(remoteGeneration)
universal.poll()
precondition(universal.detail?.item.copyCount == 1)

universalBoard.clearContents()
precondition(universalBoard.setString("Local after remote", forType: .string))
universal.universalClipboardArrived(remoteGeneration)
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
precondition(universal.total == 1)
universal.poll()
wait("new local generation") { universal.total == 2 && universal.items.first?.preview == "Local after remote" }

universalBoard.clearContents()
precondition(universalBoard.setString("1", forType: remoteType))
precondition(universalBoard.setString("Link title", forType: .string))
precondition(universalBoard.setString("https://example.com/universal-fixture", forType: .URL))
universal.poll()
wait("polling fallback for a remote link") {
    universal.total == 3 && universal.items.first?.category == .link
}
universalBoard.clearContents()
precondition(universalBoard.setString("1", forType: remoteType))
precondition(universalBoard.setData(png, forType: .png))
precondition(universalBoard.setData(bitmap.tiffRepresentation!, forType: .tiff))
universal.universalClipboardArrived(universalBoard.changeCount)
wait("universal image") { universal.total == 4 && universal.items.first?.kind == .image }
let universalImageID = universal.items.first!.id
universal.select(universalImageID)
wait("universal image snapshot") { universal.detail?.item.id == universalImageID }
precondition(universal.detail?.snapshot?.formats == ["public.png"])

// The system can expose a remote file URL before the local file is readable.
let transferredFile = root.appendingPathComponent("通用剪贴板 1.txt")
let alreadyAvailableFile = root.appendingPathComponent("通用剪贴板 2.txt")
try Data("Second file".utf8).write(to: alreadyAvailableFile)
let firstRemoteItem = NSPasteboardItem()
firstRemoteItem.setString("1", forType: remoteType)
firstRemoteItem.setString(transferredFile.absoluteString, forType: .fileURL)
firstRemoteItem.setString("File name fallback", forType: .string)
let secondRemoteItem = NSPasteboardItem()
let fileReference = (alreadyAvailableFile as NSURL).fileReferenceURL()!
secondRemoteItem.setString(fileReference.absoluteString, forType: .fileURL)
universalBoard.clearContents()
precondition(universalBoard.writeObjects([firstRemoteItem, secondRemoteItem]))
let fileGeneration = universalBoard.changeCount
universal.universalClipboardArrived(fileGeneration)
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
precondition(universal.total == 4)
try Data("Universal Clipboard test file".utf8).write(to: transferredFile)
precondition(universalBoard.changeCount == fileGeneration)
wait("same-generation universal file becomes available") {
    universal.poll()
    return universal.total == 5 && universal.items.first?.category == .files
}
let universalFileID = universal.items.first!.id
universal.select(universalFileID)
wait("universal file detail") { universal.detail?.item.id == universalFileID }
let storedFiles = universal.detail!.files.map { URL(fileURLWithPath: $0.path) }
precondition(storedFiles.map(\.lastPathComponent) == [transferredFile.lastPathComponent, alreadyAvailableFile.lastPathComponent])
precondition(storedFiles.allSatisfy { $0.path.hasPrefix(universalDirectory.appendingPathComponent("files").path + "/") })
precondition(universal.detail?.snapshot?.formats == ["public.file-url"])
try FileManager.default.removeItem(at: transferredFile)
try FileManager.default.removeItem(at: alreadyAvailableFile)
let reopenedUniversalStore = try ClipboardStore(directory: universalDirectory)
let reopenedDetail = try reopenedUniversalStore.detail(id: universalFileID)
precondition(reopenedDetail?.files.map(\.path) == storedFiles.map(\.path))
precondition(universal.copySelected())
let replayedUniversalFiles = universalBoard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]
precondition(replayedUniversalFiles?.map(\.path) == storedFiles.map(\.path))
let replayedContents = try storedFiles.map { try String(contentsOf: $0, encoding: .utf8) }
precondition(replayedContents == ["Universal Clipboard test file", "Second file"])

universalBoard.clearContents()
precondition(universalBoard.setString("1", forType: remoteType))
precondition(universalBoard.setString("1", forType: .init("org.nspasteboard.ConcealedType")))
precondition(universalBoard.setString("Sensitive universal fixture", forType: .string))
universal.universalClipboardArrived(universalBoard.changeCount)
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
precondition(universal.total == 5)

universalBoard.clearContents()
precondition(universalBoard.setString("1", forType: remoteType))
let cancelledGeneration = universalBoard.changeCount
universal.universalClipboardArrived(cancelledGeneration)
universal.savesUniversalClipboardImmediately = false
precondition(universalBoard.setString("Cancelled universal fixture", forType: .string))
precondition(universalBoard.changeCount == cancelledGeneration)
universal.poll()
RunLoop.current.run(until: Date().addingTimeInterval(0.6))
precondition(universal.total == 5)
universal.select(universalFileID)
universal.removeSelected()
wait("transferred file removal") {
    universal.total == 4 && storedFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
}
if getuid() != 0 {
    let protectedFile = root.appendingPathComponent("system-transfer-reference.txt")
    try Data("Transfer available by URL".utf8).write(to: protectedFile)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: protectedFile.path)
    let protectedItem = NSPasteboardItem()
    protectedItem.setString("1", forType: remoteType)
    protectedItem.setString(protectedFile.absoluteString, forType: .fileURL)
    universal.savesUniversalClipboardImmediately = true
    universalBoard.clearContents()
    precondition(universalBoard.writeObjects([protectedItem]))
    universal.universalClipboardArrived(universalBoard.changeCount)
    wait("protected system transfer appears in history") {
        universal.total == 5 && universal.items.first?.category == .files
    }
    universal.select(universal.items.first!.id)
    wait("protected system transfer is saved as a file reference") {
        universal.detail?.files.first?.isSystemTransferReference == true
    }
    precondition(universal.detail?.files.map(\.path) == [protectedFile.path])
    let originalTransfer = universalBoard.changeCount
    precondition(universal.copySelected())
    precondition(universalBoard.changeCount == originalTransfer)
    let urls = universalBoard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    precondition(urls?.map(\.path) == [protectedFile.path])
    universalBoard.clearContents()
    precondition(universalBoard.setString("Unrelated current content", forType: .string))
    let unrelatedChange = universalBoard.changeCount
    precondition(!universal.copySelected())
    precondition(universalBoard.changeCount == unrelatedChange)
    precondition(universalBoard.string(forType: .string) == "Unrelated current content")
    try FileManager.default.removeItem(at: protectedFile)
    precondition(!universal.copySelected())
}
universal.stopRuntime()
print("PASS universal clipboard fixtures: opt-in, arrival parsing, deferred data, stale generations, polling fallback, text/link/image/file snapshots, sensitive filtering and cancellation")

print("PASS named pasteboard: direct Chinese OCR search over historical images and Finder image files, background OCR of a new Finder image with the page closed, six categories, saved text edit and exact replay, QR decoding, color conversion, rich text/image/file replay, sensitive filtering, persistence and cleanup")

func verifyHistoryRemoval() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    let titles = ["过去 5 分钟", "过去 15 分钟", "过去 30 分钟", "过去 1 小时", "过去 24 小时"]

    func picker(in view: NSView?) -> NSPopUpButton? {
        guard let view else { return nil }
        if let picker = view as? NSPopUpButton { return picker }
        for child in view.subviews {
            if let picker = picker(in: child) { return picker }
        }
        return nil
    }

    for (index, minutes) in [5, 15, 30, 60, 1440].enumerated() {
        let suite = "org.keylane.clipboard.removal." + UUID().uuidString
        let directory = root.appendingPathComponent(suite)
        let preferences = UserDefaults(suiteName: suite)!
        let board = NSPasteboard(name: .init(suite))
        defer {
            board.releaseGlobally()
            preferences.removePersistentDomain(forName: suite)
        }
        board.clearContents()
        board.setString("Current clipboard", forType: .string)
        let generation = board.changeCount

        let store = try ClipboardStore(directory: directory)
        let end = Date()
        let cutoff = end.addingTimeInterval(-Double(minutes) * 60)
        let old = try store.capture(.text("Old but replayed"), at: cutoff.addingTimeInterval(-1))
        try store.recordReplay(id: old, at: end)
        let boundary = try store.capture(.text("Cutoff"), at: cutoff)
        let newest = try store.capture(.text("At confirmation"), at: end)
        let pinned = try store.capture(.text("Pinned"), at: end)
        try store.setPinned(id: pinned, pinned: true)
        let later = try store.capture(.text("After confirmation"), at: end.addingTimeInterval(1))

        let controller = ClipboardController(directory: directory, board: board, preferences: preferences, startTimer: false)
        defer { controller.stopRuntime() }
        wait("load synthetic history for range \(minutes)") { controller.total == 5 }
        controller.select(boundary)
        wait("load detail before deletion") { controller.selectedDetail?.item.id == boundary }
        var clockReads = 0
        let now = {
            clockReads += 1
            return end
        }

        if index == 0 {
            for recent in [true, false] {
                controller.confirmHistoryRemoval(recent: recent, in: window, now: now)
                let sheet = window.attachedSheet!
                if let picker = picker(in: sheet.contentView) { picker.selectItem(at: 4) }
                window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                wait("dismiss canceled deletion sheet") { window.attachedSheet == nil }
                precondition(clockReads == 0 && controller.total == 5 && controller.selectedID == boundary)
                let count = try store.count()
                precondition(count == 5)
            }
        }

        controller.confirmHistoryRemoval(recent: true, in: window, now: now)
        let rangeSheet = window.attachedSheet!
        let selector = picker(in: rangeSheet.contentView)!
        precondition(selector.itemTitles == titles && selector.indexOfSelectedItem == 3)
        precondition(clockReads == 0)
        selector.selectItem(at: index)
        window.endSheet(rangeSheet, returnCode: .alertSecondButtonReturn)
        wait("apply confirmed range \(minutes) and replace stale detail") {
            controller.total == 3 && controller.selectedDetail?.item.id == pinned
        }
        precondition(clockReads == 1)
        precondition(Set(controller.items.map(\.id)) == Set([old, pinned, later]))
        let removed = try store.detail(id: newest)
        precondition(removed == nil)

        if index == 0 {
            controller.confirmHistoryRemoval(recent: false, in: window)
            let allSheet = window.attachedSheet!
            precondition(picker(in: allSheet.contentView) == nil)
            window.endSheet(allSheet, returnCode: .alertSecondButtonReturn)
            wait("clear all including pinned and reset the presentation") {
                controller.total == 0 && controller.items.isEmpty && controller.selectedID == nil && controller.detail == nil
            }
            let count = try store.count()
            precondition(count == 0)
        }
        precondition(board.changeCount == generation && board.string(forType: .string) == "Current clipboard")
    }
    print("PASS bulk history deletion: all five ranges, inclusive boundaries, pinned protection, replay timestamps, cancel, clear all, selection refresh and unchanged named pasteboard")
}

try verifyHistoryRemoval()

func verifySequentialPaste() throws {
    let suite = "org.keylane.clipboard.sequence." + UUID().uuidString
    let directory = root.appendingPathComponent(suite)
    let preferences = UserDefaults(suiteName: suite)!
    let board = NSPasteboard(name: .init(suite))
    defer {
        board.releaseGlobally()
        preferences.removePersistentDomain(forName: suite)
    }
    let store = try ClipboardStore(directory: directory)
    let earlier = Date().addingTimeInterval(-30)
    let old = try store.capture(.text("Old"), at: earlier)
    let mid = try store.capture(.text("Middle"), at: earlier.addingTimeInterval(1))
    let recentText = "最新"
    let attributed = NSAttributedString(string: recentText, attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
    let richText = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                       documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    let snapshot = ClipSnapshot(items: [ClipSnapshotItem([
        .init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(recentText.utf8)),
        .init(type: NSPasteboard.PasteboardType.rtf.rawValue, data: richText)
    ])], plainText: recentText)
    let new = try store.capture(.text(recentText), snapshot: snapshot, at: earlier.addingTimeInterval(2))
    try store.setPinned(id: old, pinned: true)
    try store.recordReplay(id: mid)
    let ids = try store.sequentialPasteIDs()
    precondition(ids == [new, mid, old])

    let controller = ClipboardController(directory: directory, board: board, preferences: preferences, startTimer: false)
    wait("load synthetic sequence history") { controller.total == 3 }
    defer { controller.stopRuntime() }
    precondition(controller.sequenceTimeout == 30 && !controller.sequenceAddsNewline)

    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
    view.isRichText = true
    let targetWindow = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
    targetWindow.contentView = view
    targetWindow.makeFirstResponder(view)

    func next(target: Int32 = 41, stillFocused: Bool = true) -> Result<ClipboardController.SequencePaste, SequenceFixtureError> {
        var result: Result<ClipboardController.SequencePaste, SequenceFixtureError>?
        controller.prepareSequentialPaste(target: target, isTargetCurrent: { stillFocused }, ready: { result = .success($0) },
                                          failure: { result = .failure(.init(message: $0)) })
        wait("prepare next synthetic paste") { result != nil }
        return result!
    }
    func paste(_ text: String, target: Int32 = 41, expectsRichText: Bool = false) throws {
        let step = try next(target: target).get()
        precondition(step.isCurrent() && step.generation == board.changeCount && !step.isFile)
        precondition(board.string(forType: .string) == text)
        precondition((board.data(forType: .rtf) != nil) == expectsRichText)
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        precondition(view.readSelection(from: board))
        step.dispatched()
        step.finish()
    }

    let denied = next(stillFocused: false)
    precondition((try? denied.get()) == nil && board.string(forType: .string) == nil)
    let cancelled = try next().get()
    var overlappingCallback = false
    controller.prepareSequentialPaste(target: 41, isTargetCurrent: { true }, ready: { _ in overlappingCallback = true },
                                      failure: { _ in overlappingCallback = true })
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    precondition(!overlappingCallback)
    controller.cancelPendingSequentialPaste()
    cancelled.dispatched()
    precondition(!cancelled.isCurrent())
    try paste(recentText, expectsRichText: true)

    controller.updatesHistoryAfterReplay = true
    try store.setPinned(id: mid, pinned: true)
    controller.sequenceAddsNewline = true
    try paste("Middle\n")
    try store.setPinned(id: old, pinned: false)
    try store.removeRecent(since: earlier, through: earlier)
    let deleted = next()
    precondition((try? deleted.get()) == nil && board.string(forType: .string) == "Middle\n")
    precondition((try? next().get()) == nil)
    controller.sequenceAddsNewline = false
    controller.prefersPlainText = true
    controller.resetPasteSequence()
    try paste(recentText)
    try paste(recentText, target: 42)

    var interrupted = false
    controller.prepareSequentialPaste(target: 42, isTargetCurrent: {
        board.clearContents()
        board.setString("External", forType: .string)
        return true
    }, ready: { _ in preconditionFailure("External clipboard change was overwritten") },
       failure: { _ in interrupted = true })
    wait("protect new clipboard content before writing") { interrupted }
    precondition(board.string(forType: .string) == "External")
    let oldGeneration = try next(target: 42).get()
    board.clearContents()
    board.setString("External again", forType: .string)
    precondition(board.changeCount != oldGeneration.generation)
    oldGeneration.finish()
    try paste(recentText, target: 42)
    try paste("Middle", target: 42)
    precondition((try? next(target: 42).get()) == nil)
    precondition(view.string == recentText + "Middle\n" + recentText + recentText + recentText + "Middle")
    targetWindow.orderOut(nil)

    var sequence = ClipboardPasteSequence()
    let first = sequence.begin(target: 1, generation: 10, now: 10, timeout: 30)!
    sequence.remember(["new", "old"], for: first)
    sequence.wroteClipboard(for: first, generation: 11)
    sequence.dispatched(first, at: 11)
    sequence.dispatched(first, at: 20)
    let retry = sequence.begin(target: 1, generation: 11, now: 40, timeout: 30)!
    precondition(retry.items == ["new", "old"] && retry.index == 1)
    sequence.finish(retry)
    let timedOut = sequence.begin(target: 1, generation: 11, now: 41, timeout: 30)!
    precondition(timedOut.items == nil && timedOut.index == 0)
    sequence.reset()
    precondition(!sequence.contains(timedOut))
    print("PASS sequential paste: fixed copy order, original and plain text, newline, isolated text target, focus, busy, cancel, deleted entry, target switch, external generation, timeout and reset")
}

struct SequenceFixtureError: Error { let message: String }
try verifySequentialPaste()
