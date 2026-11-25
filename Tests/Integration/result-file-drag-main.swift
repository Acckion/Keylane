import AppKit
import SwiftUI

// Only non-drag chrome is stubbed. ResultListButton, its native overlay and payload
// are compiled from production sources; no app model or shared preferences start.
enum VisualStyle {
    static let launcherEdgeInset: CGFloat = 10
    static let launcherTopInset: CGFloat = 61
    static let launcherBottomInset: CGFloat = 52
    static let sectionText = Font.system(size: 12, weight: .medium)
}
func ThemeSelectionStyle(normalOpacity: Double, increasedOpacity: Double) -> Color { .primary.opacity(normalOpacity) }

let app = NSApplication.shared
let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEYLANE_RESULT_DRAG_TEST_ROOT"]!)
precondition(root.path.hasPrefix("/private/tmp/KeylaneResultFileDrag.") || root.path.hasPrefix("/tmp/KeylaneResultFileDrag."))
let source = root.appendingPathComponent("source")
let destination = root.appendingPathComponent("destination")
try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let first = source.appendingPathComponent("first.txt"), second = source.appendingPathComponent("second.txt")
try Data("First synthetic drag file".utf8).write(to: first)
try Data("Second synthetic drag file".utf8).write(to: second)
let folder = source.appendingPathComponent("folder")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
try Data("Nested synthetic drag file".utf8).write(to: folder.appendingPathComponent("nested.txt"))

func verify() throws {
    let files = try ResultFileDragPayload(urls: [first, second, folder])
    precondition(files.urls == [first, second, folder])
    do { _ = try ResultFileDragPayload(urls: [source.appendingPathComponent("missing")]); preconditionFailure("missing file accepted") } catch {}
    do { _ = try ResultFileDragPayload(urls: [URL(string:"https://example.com")!]); preconditionFailure("non-file URL accepted") } catch {}
    final class Owner {}
    var owner: Owner? = Owner(); weak var weakOwner = owner
    var retained: ResultFileDragPayload? = try ResultFileDragPayload(urls: [first], retaining: owner)
    owner = nil; precondition(retained?.urls == [first] && weakOwner != nil)
    retained = nil; precondition(weakOwner == nil)
    // Read permissions can disappear after a row was indexed. Do not start a new drag.
    let restricted = source.appendingPathComponent("restricted.txt")
    try Data("Permission fixture".utf8).write(to: restricted)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restricted.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: restricted.path) }
    do { _ = try ResultFileDragPayload(urls: [restricted]); preconditionFailure("unreadable file accepted") } catch {}
    do { _ = try ResultFileDragPayload(urls: [first, restricted]); preconditionFailure("partially unreadable group accepted") } catch {}
    // Actual NSURL pasteboard serialization, but not a Finder drop or NSDraggingSession.
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    precondition(board.writeObjects(files.urls.map { $0 as NSURL }))
    let decoded = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as! [URL]
    precondition(decoded == files.urls)
    let transportCopy = root.appendingPathComponent("transport-copy-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: transportCopy, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: transportCopy) }
    for url in decoded { try FileManager.default.copyItem(at: url, to: transportCopy.appendingPathComponent(url.lastPathComponent)) }
    for relative in ["first.txt", "second.txt", "folder/nested.txt"] {
        precondition(try! Data(contentsOf: source.appendingPathComponent(relative)) == Data(contentsOf: transportCopy.appendingPathComponent(relative)))
    }
    let window = NSWindow(contentRect:NSRect(x:100,y:100,width:400,height:150),styleMask:[.titled],backing:.buffered,defer:false)
    let view = ResultFileDragView(frame:NSRect(x:0,y:0,width:350,height:40))
    window.contentView!.addSubview(view)
    var clicks = 0, selections = 0, preparations = 0
    view.click = { clicks += 1 }
    view.source = ResultFileDrag(id:"synthetic",select:{selections += 1},prepare:{ completion in preparations += 1; completion(nil) })
    func event(_ kind: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with:kind,location:NSPoint(x:x,y:20),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
    }
    view.mouseDown(with:event(.leftMouseDown,10)); view.mouseUp(with:event(.leftMouseUp,10))
    precondition(clicks == 1 && selections == 0 && preparations == 0)
    view.mouseDown(with:event(.leftMouseDown,10)); view.mouseDragged(with:event(.leftMouseDragged,12))
    precondition(preparations == 0)
    view.mouseDragged(with:event(.leftMouseDragged,30)); view.mouseDragged(with:event(.leftMouseDragged,40))
    view.mouseUp(with:event(.leftMouseUp,40))
    precondition(clicks == 1 && selections == 1 && preparations == 1)
    var pending: ((ResultFileDragPayload?) -> Void)?
    view.source = ResultFileDrag(id:"delayed",select:{},prepare:{ pending = $0 })
    func latePayloadIsReleased() throws {
        var owner: Owner? = Owner(); weak var observed = owner
        var payload: ResultFileDragPayload? = try ResultFileDragPayload(urls: [first], retaining: owner)
        owner = nil
        pending?(payload); pending = nil; payload = nil
        precondition(observed == nil, "Cancelled preparation retained its payload")
    }
    view.mouseDown(with:event(.leftMouseDown,10)); view.mouseDragged(with:event(.leftMouseDragged,30))
    precondition(pending != nil)
    view.mouseUp(with:event(.leftMouseUp,30)); try latePayloadIsReleased()
    view.mouseDown(with:event(.leftMouseDown,10)); view.mouseDragged(with:event(.leftMouseDragged,30))
    view.cancelPreparation() // Same invalidation used for row identity change/dismantle.
    view.removeFromSuperview(); window.orderOut(nil)
    try latePayloadIsReleased()
    precondition(clicks == 1)
    print("RESULT_FILE_DRAG_PAYLOAD_CLICK_THRESHOLD_CANCEL_OK")
    print("RESULT_FILE_DRAG_LATE_CALLBACK_UNREADABLE_GROUP_URL_TRANSPORT_OK (not Finder/session acceptance)")
}
try verify()
if CommandLine.arguments.contains("--ui") {
    struct Fixture: View {
        let root: URL, first: URL, second: URL, folder: URL
        @State private var clicks = 0
        @State private var selected = "None"
        @State private var hideDuringDrag = false
        var body: some View {
            VStack(alignment:.leading,spacing:18) {
                Text("Keylane 文件拖拽测试").font(.title2)
                Text("点击：\(clicks) · 选中：\(selected)")
                Toggle("拖动开始后隐藏测试窗口（5 秒后仅恢复显示）", isOn: $hideDuringDrag)
                row("单个文件 first.txt", files:[first])
                row("文件组 first.txt + second.txt",files:[first,second])
                row("文件夹 folder",files:[folder])
                Text("仅使用临时合成文件。拖出为复制，取消不会打开项目。").font(.caption)
                Button("打开合成文件接收目录") { NSWorkspace.shared.open(root.appendingPathComponent("destination")) }
            }.padding(24).frame(width:510,height:350)
        }
        func row(_ title: String, files: [URL]) -> some View {
            ResultListButton(id:title, fileDrag:.init(id:title, select:{
                selected=title
                if hideDuringDrag, let window = NSApp.keyWindow {
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                        window.orderOut(nil)
                        DispatchQueue.main.asyncAfter(deadline:.now()+5) { window.orderFront(nil) }
                    }
                }
            },prepare:{ completion in completion(try? ResultFileDragPayload(urls:files)) }), action:{ clicks += 1 }) {
                HStack { Image(systemName:"doc"); Text(title); Spacer() }.padding(10).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
            }
        }
    }
    app.setActivationPolicy(.regular)
    let window = NSWindow(contentRect:NSRect(x:100,y:350,width:558,height:398),styleMask:[.titled,.closable],backing:.buffered,defer:false)
    window.title = "Keylane File Drag Test"
    window.contentView = NSHostingView(rootView:Fixture(root:root,first:first,second:second,folder:folder))
    window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps:true)
    print("RESULT_FILE_DRAG_UI_READY \(root.path)"); fflush(stdout)
    app.run()
}
