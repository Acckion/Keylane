import AppKit
import SwiftUI

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
    print("RESULT_FILE_DRAG_PAYLOAD_CLICK_THRESHOLD_CANCEL_OK")
}
try verify()
if CommandLine.arguments.contains("--ui") {
    struct Fixture: View {
        let root: URL, first: URL, second: URL, folder: URL
        @State private var clicks = 0
        @State private var selected = "None"
        var body: some View {
            VStack(alignment:.leading,spacing:18) {
                Text("Keylane 文件拖拽测试").font(.title2)
                Text("点击：\(clicks) · 选中：\(selected)")
                row("单个文件 first.txt", files:[first])
                row("文件组 first.txt + second.txt",files:[first,second])
                row("文件夹 folder",files:[folder])
                Text("仅使用临时合成文件。拖出为复制，取消不会打开项目。").font(.caption)
            }.padding(24).frame(width:510,height:280)
        }
        func row(_ title: String, files: [URL]) -> some View {
            Button { clicks += 1 } label: {
                HStack { Image(systemName:"doc"); Text(title); Spacer() }.padding(10).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
            }.buttonStyle(.plain).overlay {
                ResultFileDragSurface(source: .init(id:title,select:{selected=title},prepare:{ completion in
                    completion(try? ResultFileDragPayload(urls:files))
                }),click:{clicks += 1}).accessibilityHidden(true)
            }
        }
    }
    app.setActivationPolicy(.regular)
    let window = NSWindow(contentRect:NSRect(x:100,y:350,width:558,height:328),styleMask:[.titled,.closable],backing:.buffered,defer:false)
    window.title = "Keylane File Drag Test"
    window.contentView = NSHostingView(rootView:Fixture(root:root,first:first,second:second,folder:folder))
    window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps:true)
    print("RESULT_FILE_DRAG_UI_READY \(root.path)"); fflush(stdout)
    app.run()
}
