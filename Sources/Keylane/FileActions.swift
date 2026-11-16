import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum FilePresentationOwner: Equatable {
    case fileSearch, clipboard, screenshots
    case extensionActivation(UUID)
}

final class FileActionsModel: ObservableObject {
    @Published private(set) var files: [URL] = []
    var file: URL? { files.first }
    @Published private(set) var applications: [URL] = []
    @Published var selectedApplication = ""
    @Published var page = "open"
    @Published private(set) var status = ""
    @Published private(set) var opening = false
    @Published var shareRequest = 0
    private var defaultApplication: URL?
    private var fileAccess: AnyObject?
    private var generation = 0
    var opened: (() -> Void)?
    var isAvailable: Bool { !files.isEmpty && files.allSatisfy { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) } }
    func configure(_ urls: [URL], page: String, retaining access: AnyObject?) {
        generation += 1; files = urls; self.page = page; opening = false; status = ""; applications = []; selectedApplication = ""
        fileAccess = access
        guard let url = files.first, validate() else { return }
        defaultApplication = NSWorkspace.shared.urlForApplication(toOpen:url)
        var compatible = NSWorkspace.shared.urlsForApplications(toOpen:url)
        for other in files.dropFirst() {
            let available = Set(NSWorkspace.shared.urlsForApplications(toOpen: other).map(\.standardizedFileURL))
            compatible = compatible.filter { available.contains($0.standardizedFileURL) }
        }
        if files.count > 1, let app = defaultApplication, !compatible.contains(app) { defaultApplication = nil }
        var seen = Set<String>()
        applications = ((defaultApplication.map { [$0] } ?? []) + compatible).filter { seen.insert($0.standardizedFileURL.path).inserted }
        selectedApplication = applications.first?.path ?? ""
        if applications.isEmpty { status = "没有找到适用的应用，可选择其他应用。" }
    }
    func applicationTitle(_ url: URL) -> String {
        let name = FileManager.default.displayName(atPath:url.path).replacingOccurrences(of:".app",with:"")
        return name + (url.standardizedFileURL == defaultApplication?.standardizedFileURL ? "（默认）" : "")
    }
    @discardableResult func validate() -> Bool {
        guard isAvailable else { status = "文件已移走、删除或磁盘已断开。请重新搜索。"; return false }
        return true
    }
    func chooseApplication() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath:"/Applications"); panel.prompt = "选择应用"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !applications.contains(url) { applications.append(url) }; selectedApplication = url.path
    }
    func openSelected() {
        guard !opening, validate(), !selectedApplication.isEmpty else { return }
        let application = URL(fileURLWithPath:selectedApplication)
        guard FileManager.default.fileExists(atPath:application.path), application.pathExtension.lowercased() == "app" else { status = "所选应用已不可用，请重新选择。"; return }
        generation += 1; let ticket = generation; opening = true; status = "正在打开…"
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        NSWorkspace.shared.open(files,withApplicationAt:application,configuration:configuration) { [weak self, fileAccess] app,error in
            DispatchQueue.main.async {
                defer { withExtendedLifetime(fileAccess) {} }
                guard let self, self.generation == ticket else { return }
                self.opening = false
                guard error == nil, app != nil else { self.status = "无法用所选应用打开文件：" + (error?.localizedDescription ?? "应用未能启动。"); return }
                self.status = "已交给所选应用打开"; self.opened?()
            }
        }
    }
    func releaseFiles() {
        generation += 1
        fileAccess = nil
        files = []
        applications = []
        defaultApplication = nil
        selectedApplication = ""
        opening = false
    }
    func feedback(_ message: String) { status = message }
}

final class FileActionsWindow: NSObject, NSWindowDelegate {
    static let shared = FileActionsWindow()
    let model = FileActionsModel()
    var onEscape: (() -> Void)?
    var onActivate: ((NSWindow) -> Void)?
    private var window: NSWindow?
    private var owner: FilePresentationOwner?
    func show(_ file: URL, page: String, owner: FilePresentationOwner? = nil) { show([file], page: page, owner: owner) }

    func show(_ files: [URL], page: String, retaining access: AnyObject? = nil, owner: FilePresentationOwner? = nil) {
        self.owner = owner
        model.configure(files, page: page, retaining: access)
        if window == nil {
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:520,height:350),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window.title = "文件操作"; window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: FileActionsView(model: model)
                .onExitCommand { [weak self] in self?.onEscape?() })
            window.minSize = NSSize(width:450,height:300); window.center(); window.delegate = self
            self.window = window
            model.opened = { [weak self] in self?.window?.close() }
        }
        if let window {
            onActivate?(window)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        if page == "share", model.isAvailable { model.shareRequest += 1 }
    }
    func dismiss(owner: FilePresentationOwner) {
        guard self.owner == owner else { return }
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) { owner = nil; model.releaseFiles() }
}
private struct FileActionsView: View {
    @ObservedObject var model: FileActionsModel
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            if let file = model.file {
                HStack(spacing:12) {
                    Image(nsImage:NSWorkspace.shared.icon(forFile:file.path)).resizable().scaledToFit().frame(width:40,height:40)
                    VStack(alignment:.leading,spacing:4) {
                        Text(model.files.count > 1 ? "\(model.files.count) 个文件" : file.lastPathComponent).font(.headline).lineLimit(2)
                        Text(file.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    }
                }
            }
            Picker("操作",selection:$model.page) { Text("打开方式").tag("open"); Text("分享").tag("share") }.pickerStyle(.segmented).labelsHidden()
            if model.page == "open" {
                Picker("使用应用",selection:$model.selectedApplication) {
                    if model.applications.isEmpty { Text("请选择应用").tag("") }
                    ForEach(model.applications,id:\.path) { app in Text(model.applicationTitle(app)).tag(app.path) }
                }.pickerStyle(.menu)
                HStack { Button("其他应用…") { model.chooseApplication() }.buttonStyle(.glass); Spacer(); Button("打开") { model.openSelected() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(model.selectedApplication.isEmpty || model.opening || !model.isAvailable) }
                Text("仅此次使用所选应用，不修改系统默认打开方式。").font(.caption).foregroundStyle(.secondary)
            } else {
                NativeFileShareButton(model:model).frame(height:32)
                Text("使用 macOS 系统分享菜单。选择服务后，由系统继续完成操作。").font(.caption).foregroundStyle(.secondary)
            }
            if !model.status.isEmpty { Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Spacer(minLength:0)
        }.padding(24)
    }
}
private struct NativeFileShareButton: NSViewRepresentable {
    @ObservedObject var model: FileActionsModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context:Context) -> NSButton {
        let button = NSButton(title:"分享…",target:context.coordinator,action:#selector(Coordinator.show(_:))); button.bezelStyle = .rounded
        return button
    }
    func updateNSView(_ button:NSButton,context:Context) {
        context.coordinator.model = model; button.isEnabled = model.isAvailable
        if model.page == "share", model.shareRequest > context.coordinator.lastRequest {
            context.coordinator.lastRequest = model.shareRequest
            context.coordinator.presentWhenReady(button,attempt:0)
        }
    }
    final class Coordinator: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        var model: FileActionsModel
        var lastRequest = 0
        private var picker: NSSharingServicePicker?
        private var sharingFiles: [URL] = []
        init(_ model:FileActionsModel) { self.model = model }
        func presentWhenReady(_ button:NSButton,attempt:Int) {
            DispatchQueue.main.asyncAfter(deadline:.now() + (attempt == 0 ? 0 : 0.05)) { [weak self,weak button] in
                guard let self,let button,self.model.page == "share" else { return }
                if button.window?.isVisible == true { self.show(button) }
                else if attempt < 3 { self.presentWhenReady(button,attempt:attempt+1) }
            }
        }
        @objc func show(_ sender:NSButton) {
            guard model.validate(), sender.window?.isVisible == true else { return }
            sharingFiles = model.files
            let picker = NSSharingServicePicker(items: sharingFiles); picker.delegate = self; self.picker = picker
            picker.show(relativeTo:sender.bounds,of:sender,preferredEdge:.minY)
        }
        func sharingServicePicker(_ sharingServicePicker:NSSharingServicePicker,didChoose service:NSSharingService?) { guard model.files == sharingFiles else { return }; model.feedback(service == nil ? "已取消分享" : "已选择系统分享服务") }
        func sharingServicePicker(_ sharingServicePicker:NSSharingServicePicker,delegateFor sharingService:NSSharingService) -> NSSharingServiceDelegate? { self }
        func sharingService(_ sharingService:NSSharingService,didShareItems items:[Any]) { guard model.files == sharingFiles else { return }; model.feedback("系统分享服务已完成") }
        func sharingService(_ sharingService:NSSharingService,didFailToShareItems items:[Any],error:Error) { guard model.files == sharingFiles else { return }; model.feedback("分享未完成：" + error.localizedDescription) }
    }
}
