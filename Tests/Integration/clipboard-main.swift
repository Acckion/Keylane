import Foundation
import AppKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
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
