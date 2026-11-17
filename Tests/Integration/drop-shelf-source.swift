// Independent native app used for physical cross-process file-promise acceptance tests.
import AppKit
import UniformTypeIdentifiers

final class PromiseSource: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    struct Payload { let name: String; let delay: TimeInterval; let fail: Bool }
    let queue = OperationQueue()
    override init(frame: NSRect) {
        super.init(frame: frame)
        queue.maxConcurrentOperationCount = 3
        let text = NSTextField(wrappingLabelWithString: "拖动以下区域到暂存架\n\n① 两个文件承诺（1 秒）\n\n② 失败的文件承诺（1 秒）\n\n③ 慢速承诺（6 秒，可取消）")
        text.frame = bounds.insetBy(dx: 22, dy: 15); text.autoresizingMask = [.width, .height]; text.font = .systemFont(ofSize: 16)
        addSubview(text)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let fail = point.y < 140 && point.y > 75
        let slow = point.y <= 75
        let count = fail || slow ? 1 : 2
        let items = (0..<count).map { index -> NSDraggingItem in
            let provider = NSFilePromiseProvider(fileType: UTType.plainText.identifier, delegate: self)
            provider.userInfo = Payload(name: (fail ? "failed" : slow ? "slow" : "promise-\(index + 1)") + ".txt", delay: slow ? 6 : 1, fail: fail)
            let item = NSDraggingItem(pasteboardWriter: provider)
            item.setDraggingFrame(NSRect(x: point.x, y: point.y, width: 32, height: 32), contents: NSImage(systemSymbolName: "doc", accessibilityDescription: nil))
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { (filePromiseProvider.userInfo as! Payload).name }
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        let value = filePromiseProvider.userInfo as! Payload
        Thread.sleep(forTimeInterval: value.delay)
        do {
            if value.fail { throw NSError(domain: "KeylaneSyntheticPromise", code: 1, userInfo: [NSLocalizedDescriptionKey: "合成文件提供方失败"]) }
            try Data(("Synthetic " + value.name).utf8).write(to: url, options: .withoutOverwriting)
            completionHandler(nil)
        } catch { completionHandler(error) }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 550, y: 200, width: 340, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Keylane Promise Source — Synthetic"
window.isReleasedWhenClosed = false
let source = PromiseSource(frame: NSRect(x: 0, y: 0, width: 340, height: 240))
window.contentView = source
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
