import SwiftUI
import AppKit
import Combine
import KeylaneCore

struct DropShelfHistoryView: View {
    @ObservedObject var controller: DropShelfController
    let query: String
    var body: some View {
        ResultDetailLayout(hasResults: !controller.managedShelves.isEmpty) {
            SelectableResultList(selection: controller.selectedShelfID, query: query, firstResult: controller.managedShelves.first?.id) {
                shelfSection("已固定", pinned: true)
                shelfSection("最近的暂存架", pinned: false)
            }
        } detail: {
            if let shelf = controller.selectedShelf {
                ResultDetailPane(scrollsPreview: false) { height in
                    DropShelfHistoryPreview(shelf: shelf, store: controller.store, active: controller.managementActive)
                        .id(shelf.id).frame(height: height)
                } information: {
                    if shelf.items.isEmpty {
                        Text("此暂存架为空。打开浮动暂存架后可拖入内容。")
                            .font(VisualStyle.rowText).foregroundStyle(.secondary)
                    }
                    ForEach(shelf.items) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(item.title, systemImage: symbol(item.kind)).font(VisualStyle.rowText)
                            if let value = item.value {
                                Text(String(value.prefix(4000))).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            } else if let url = item.url {
                                Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } emptyState: {
            ResultDetailEmptyState(title: query.isEmpty && controller.shelfFilter == "all" ? "没有暂存架" : "没有匹配结果",
                                   message: controller.error.isEmpty ? "使用「新建暂存架」或拖入菜单栏图标来收集内容。" : controller.error)
        }
        .onAppear { controller.beginManagement(query) }
        .onChange(of: query) { _, value in controller.searchShelves(value) }
        .onReceive(controller.$error.removeDuplicates()) { message in
            guard !message.isEmpty else { return }
            (NSApp.delegate as? Delegate)?.showLauncherFeedback(message, style: .failure)
        }
        .confirmationDialog("移除此暂存架？", isPresented: Binding(get: { controller.pendingRemoval != nil }, set: { if !$0 { controller.pendingRemoval = nil } }), presenting: controller.pendingRemoval) { shelf in
            Button("移除暂存架", role: .destructive) { controller.removeManagedShelf(shelf.id) }
            Button("取消", role: .cancel) { controller.pendingRemoval = nil }
        } message: { _ in
            Text("将移除这份暂存记录及其中保存的文字和图片。不会删除或移动外部源文件。")
        }
        .sheet(item: $controller.pendingRename) { shelf in
            DropShelfRenameForm(shelf: shelf, controller: controller)
        }
    }
    @ViewBuilder private func shelfSection(_ title: String, pinned: Bool) -> some View {
        let shelves = controller.managedShelves.filter { $0.pinned == pinned }
        if !shelves.isEmpty {
            ResultListSection(title: title, isFirst: pinned || !controller.managedShelves.contains(where: \.pinned)) {
                ForEach(shelves) { shelf in
                    ResultListButton(id: shelf.id, action: { controller.selectedShelfID = shelf.id }) {
                        ResultListRow(selected: shelf.id == controller.selectedShelfID) {
                            Image(systemName: shelf.pinned ? "pin.fill" : "tray.full").foregroundStyle(.secondary)
                        } content: {
                            VStack(alignment: .leading, spacing: 2) {
                                HighlightedResultText(text: shelf.title, query: query).font(VisualStyle.rowText).lineLimit(1)
                                Text("\(shelf.items.count) 项 · " + (shelf.items.first?.title ?? "空暂存架"))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }
    private func symbol(_ kind: DropShelfStore.Item.Kind) -> String {
        switch kind { case .file: "doc"; case .image: "photo"; case .text: "text.alignleft"; case .link: "link" }
    }
}

private struct DropShelfRenameForm: View {
    let shelf: DropShelfStore.Shelf
    @ObservedObject var controller: DropShelfController
    @State private var name: String
    init(shelf: DropShelfStore.Shelf, controller: DropShelfController) {
        self.shelf = shelf; self.controller = controller; _name = State(initialValue: shelf.title)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重命名暂存架").font(.headline)
            TextField("名称", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { controller.pendingRename = nil }.keyboardShortcut(.cancelAction)
                Button("保存") { controller.renameManagedShelf(shelf.id, title: name.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 360)
    }
}

private struct DropShelfHistoryPreview: View {
    let shelf: DropShelfStore.Shelf
    let store: DropShelfStore?
    let active: Bool
    @State private var urls: [URL] = []
    @State private var access: DropShelfHistoryAccess?
    @State private var failure = ""
    var body: some View {
        Group {
            if !urls.isEmpty {
                ResultFilePreview(urls: urls)
            } else if let first = shelf.items.first, let value = first.value {
                ScrollView { Text(String(value.prefix(8000))).font(VisualStyle.rowText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "tray").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(failure.isEmpty ? "此暂存架为空" : failure).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { if active { load() } }
        .onChange(of: shelf.items) { _, _ in if active { load() } }
        .onChange(of: active) { _, value in if value { load() } else { urls = []; access = nil } }
        .onDisappear { urls = []; access = nil }
    }
    private func load() {
        urls = []; access = nil; failure = ""
        do {
            let resolved = try shelf.items.prefix(3).compactMap { try store?.resolve($0) }
            let grants = DropShelfHistoryAccess(resolved)
            guard resolved.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }) else {
                failure = "原文件不可用或需要重新授权"; return
            }
            access = grants; urls = resolved
        } catch { failure = error.localizedDescription }
    }
}

private final class DropShelfHistoryAccess {
    let scoped: [URL]
    init(_ urls: [URL]) { scoped = urls.filter { $0.startAccessingSecurityScopedResource() } }
    deinit { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
}
