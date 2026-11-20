import SwiftUI
import AppKit
import Combine
import KeylaneCore

struct DropShelfHistoryView: View {
    @ObservedObject var controller: DropShelfController
    let query: String
    private let spacing: CGFloat = 12
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - 2 * VisualStyle.launcherEdgeInset
            let columns = max(1, Int((width + spacing) / (150 + spacing)))
            ScrollViewReader { proxy in
                ResultListScrollView {
                    if controller.managedShelves.isEmpty {
                        ResultDetailEmptyState(title: query.isEmpty && controller.shelfFilter == "all" ? "没有暂存架" : "没有匹配结果",
                                               message: controller.error.isEmpty ? "使用「新建暂存架」或拖入菜单栏图标来收集内容。" : controller.error)
                            .frame(maxWidth: .infinity)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
                                  spacing: spacing) {
                            ForEach(controller.managedShelves) { shelf in
                                DropShelfHistoryCard(shelf: shelf, controller: controller)
                                    .id(shelf.id)
                            }
                        }
                        .padding(.vertical, spacing)
                    }
                }
                .onChange(of: controller.selectedShelfID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                .onChange(of: columns, initial: true) { _, value in
                    controller.managementGridColumns = value
                    if let id = controller.selectedShelfID { proxy.scrollTo(id) }
                }
            }
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
}

private struct DropShelfHistoryCard: View {
    let shelf: DropShelfStore.Shelf
    @ObservedObject var controller: DropShelfController
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovered = false
    @State private var pinHovered = false
    @State private var menuHovered = false

    private var onDesktop: Bool { controller.isShelfOpen(shelf.id) }
    private var selected: Bool { controller.selectedShelfID == shelf.id }
    private var hasCustomName: Bool { shelf.title != "暂存架" }
    private var summary: String {
        if shelf.items.isEmpty { return "空暂存架" }
        if shelf.items.count == 1 { return shelf.items[0].title }
        return "\(shelf.items.count) 项"
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: VisualStyle.launcherCornerRadius, style: .continuous)
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .background {
                shape.fill(reduceTransparency ? Color(nsColor: .windowBackgroundColor) : .clear)
                    .glassEffect(reduceTransparency ? .identity : LauncherGlassMaterial.swiftUI, in: shape)
            }
            .overlay {
                Button { controller.openManagedShelf(shelf.id) } label: {
                    GeometryReader { geometry in
                        let horizontalInset: CGFloat = 10
                        let contentWidth = max(0, geometry.size.width - 2 * horizontalInset)
                        let topInset: CGFloat = 33
                        let bottomInset: CGFloat = 10
                        let capsuleHeight: CGFloat = 26
                        let nameHeight: CGFloat = hasCustomName ? 17 : 0
                        let previewHeight = max(0, geometry.size.height - topInset - bottomInset - capsuleHeight - nameHeight - 3)
                        VStack(spacing: 3) {
                            DropShelfCardPreview(shelf: shelf, store: controller.store, active: controller.managementActive)
                                .frame(width: contentWidth, height: previewHeight)
                                .clipped()
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            if hasCustomName {
                                Text(shelf.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .frame(height: nameHeight - 3)
                            }
                            Text(summary)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 12)
                                .frame(height: capsuleHeight)
                                .background(.primary.opacity(0.08), in: Capsule())
                        }
                        .frame(width: contentWidth)
                        .padding(.top, topInset)
                        .padding(.bottom, bottomInset)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    .contentShape(shape)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(shelf.title + "，" + summary)
                .accessibilityHint("打开浮动暂存架")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            .overlay(alignment: .top) {
                HStack {
                    Button { controller.toggleManagedPin(shelf.id) } label: {
                        control(onDesktop ? "pin.fill" : "pin", hovered: pinHovered)
                    }
                    .buttonStyle(.plain)
                    .onHover { pinHovered = $0 }
                    .accessibilityLabel(onDesktop ? "取消固定" : "固定到桌面")
                    .help(onDesktop ? "取消固定" : "固定到桌面")
                    Spacer()
                    Menu {
                        Button("重命名…") { controller.pendingRename = shelf }
                        Button("从桌面关闭") { controller.closeManagedShelf(shelf.id) }
                            .disabled(!controller.isShelfOpen(shelf.id))
                        Divider()
                        Button("删除暂存架…", role: .destructive) { controller.pendingRemoval = shelf }
                    } label: {
                        control("ellipsis", hovered: menuHovered)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .onHover { menuHovered = $0 }
                    .accessibilityLabel("暂存架操作")
                    .help("暂存架操作")
                }
                .padding(7)
            }
            .overlay {
                shape.strokeBorder(.primary.opacity(selected ? 0.55 : hovered ? 0.24 : 0.10),
                                   lineWidth: selected ? 1.5 : 1)
                    .allowsHitTesting(false)
            }
            .onHover { hovered = $0 }
    }

    private func control(_ symbol: String, hovered: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 30, height: 30)
            .background(.primary.opacity(hovered ? 0.19 : 0.07), in: Circle())
            .glassEffect(reduceTransparency ? .identity : LauncherGlassMaterial.swiftUI, in: Circle())
            .contentShape(Circle())
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

private struct DropShelfCardPreview: NSViewRepresentable {
    let shelf: DropShelfStore.Shelf
    let store: DropShelfStore?
    let active: Bool

    func makeCoordinator() -> DropShelfThumbnails { DropShelfThumbnails() }

    func makeNSView(context: Context) -> DropShelfPreview {
        let view = DropShelfPreview(frame: .zero)
        view.unregisterDraggedTypes()
        view.setAccessibilityElement(false)
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DropShelfPreview, context: Context) -> CGSize? {
        // Stacked AppKit images can report a wider fitting size once their rotated layers load.
        // The card defines the preview's bounds regardless of those intrinsic dimensions.
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    func updateNSView(_ view: DropShelfPreview, context: Context) {
        view.placeholder.isHidden = !shelf.items.isEmpty
        view.placeholder.stringValue = "暂无内容"
        guard active, let store else {
            context.coordinator.cancel()
            view.setImages([])
            return
        }
        context.coordinator.update(items: shelf.items, store: store, scale: context.environment.displayScale) { [weak view] images in
            view?.setImages(images)
        }
    }

    static func dismantleNSView(_ view: DropShelfPreview, coordinator: DropShelfThumbnails) {
        coordinator.cancel()
    }
}
