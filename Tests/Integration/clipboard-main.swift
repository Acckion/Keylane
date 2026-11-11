import Foundation
import AppKit
import Combine
import KeylaneCore

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

controller.recognizeSelected()
wait("Vision OCR") { controller.detail?.ocrText.contains("KEYLANE") == true }
controller.search("OCR 123"); wait("OCR search") { controller.items.count == 1 && controller.items.first?.id == image.id }
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
let firstItem = NSPasteboardItem(); firstItem.setString("多个项目里的文字",forType:.string)
let secondItem = NSPasteboardItem(); secondItem.setData(png,forType:.png)
board.clearContents(); board.writeObjects([firstItem,secondItem]); controller.poll()
wait("multiple representations") { controller.total == 2 }
let mixedID = controller.items.first { $0.id != richID }!.id
controller.select(mixedID); wait("mixed detail") { controller.detail?.item.id == mixedID && !controller.loadingDetail }
precondition(controller.detail?.snapshot?.items.count == 2)
precondition(controller.copySelected())
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
controller.clear(includePinned:true); wait("cleanup final") { controller.total == 0 }
// Automatic monitor regression: no explicit poll calls, including while the app is inactive.
let automaticSuite = suite + ".automatic"
let automaticPrefs = UserDefaults(suiteName:automaticSuite)!
automaticPrefs.set(true,forKey:"clipboardPersistentCapture")
let automaticBoard = NSPasteboard(name:.init(automaticSuite))
let automatic = ClipboardController(directory:root.appendingPathComponent("automatic"),board:automaticBoard,preferences:automaticPrefs)
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
precondition(FileManager.default.fileExists(atPath:copiedImageFile.path))



print("PASS named pasteboard: automatic timer text/image capture, rich RTF/HTML exact roundtrip, plain copy, mixed items, inert HTML, stable detail, default-off, text, dedupe, stable pin, replay exclusion, sensitive exclusion, native PNG roundtrip, Vision OCR/search, file roundtrip, original retained, reopen, clear policies")
