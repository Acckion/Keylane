import AppKit
import UniformTypeIdentifiers
import KeylaneCore

enum ClipboardResultActions {
    static func actions(_ controller: ClipboardController, delegate: Delegate?) -> [LauncherAction] {
        let deleteActions = bulkDeleteActions(controller)
        guard let item = controller.items.first(where: { $0.id == controller.selectedID }) else { return deleteActions }
        let target = delegate?.pasteTarget
        let icon = target?.icon
        let paste: (ClipboardPasteFormat, Bool) -> Void = { [weak delegate] format, keepOpen in
            guard controller.selectedID == item.id else { return }
            delegate?.pasteClipboard(format: format, target: target, keepLauncherOpen: keepOpen)
        }
        let canPaste = target != nil && controller.readyDetail != nil
        let formats = controller.availablePasteFormats.map { format in
            LauncherAction(id: "paste-format-" + format.rawValue, title: format.title,
                           icon: "doc.on.clipboard", image: icon) {
                paste(format, false)
            }
        }
        let canExport = controller.readyDetail != nil && item.kind != .files
        var actions: [LauncherAction] = [
            .init(id: "paste-clip", title: target?.localizedName.map { "粘贴到\($0)" } ?? "粘贴到目标应用",
                  icon: "doc.on.clipboard", keys: ["⌘", "↩"], image: icon, enabled: canPaste) {
                paste(.original, false)
            },
            .init(id: "paste-keep-open", title: "粘贴并保持窗口打开",
                  icon: "doc.on.clipboard", image: icon, enabled: canPaste) {
                paste(.original, true)
            },
            .init(id: "paste-as", title: "粘贴为…", icon: "doc.on.clipboard", keys: ["›"],
                  submenu: .init(title: "粘贴为", items: formats), image: icon, enabled: canPaste && !formats.isEmpty),
            .init(id: "copy-clip", title: "粘贴到剪贴板", icon: "doc.on.doc",
                  keys: controller.primaryAction == "paste" ? [] : ["↩"], enabled: controller.readyDetail != nil) {
                if controller.selectedID == item.id { controller.copySelected() }
            },
            .init(id: "share-clip", title: "分享", icon: "square.and.arrow.up", group: 1, enabled: canExport) { [weak delegate] in
                guard let detail = controller.readyDetail, detail.item.id == item.id,
                      let view = delegate?.window?.contentView else { return }
                share(detail, from: view, controller: controller)
            },
            // TODO: Integrate a content editor with history identity and snapshots.
            .init(id: "edit-clip", title: "编辑（待实现）", icon: "pencil", group: 1, enabled: false),
            // TODO: Add user-defined display names and include them in history search.
            .init(id: "rename-clip", title: "重命名（待实现）", icon: "text.cursor", group: 1, enabled: false),
            // TODO: Connect explicit clipboard attachments once AI Chat is available.
            .init(id: "ai-chat-clip", title: "发送给 AI Chat（待实现）", icon: "sparkles", group: 1, enabled: false),
            .init(id: "pin-clip", title: item.pinned ? "取消置顶" : "置顶", icon: item.pinned ? "pin.slash" : "pin", group: 1) {
                if controller.selectedID == item.id { controller.pinSelected() }
            }
        ]
        if item.kind == .image {
            actions.append(.init(id: "ocr-clip", title: "识别图片文字", icon: "text.viewfinder", group: 1) {
                if controller.selectedID == item.id { controller.recognizeSelected() }
            })
        }
        actions += [
            // TODO: Use the Snippets module when it is available.
            .init(id: "snippet-clip", title: "保存为片段（待实现）", icon: "text.badge.plus", group: 2, enabled: false),
            .init(id: "save-clip", title: "保存为文件", icon: "square.and.arrow.down", group: 2, enabled: canExport) {
                if let detail = controller.readyDetail, detail.item.id == item.id { save(detail, controller: controller) }
            },
            .init(id: "delete-clip", title: "删除", icon: "trash", group: 3, destructive: true) {
                controller.remove(id: item.id)
            }
        ]
        return actions + deleteActions
    }

    private static func bulkDeleteActions(_ controller: ClipboardController) -> [LauncherAction] {
        [
            .init(id: "delete-recent-clips", title: "删除最近…", icon: "clock.arrow.circlepath",
                  group: 3, enabled: controller.total > 0, destructive: true) {
                let through = Date()
                if confirm("删除最近一小时的记录？", detail: "保留已置顶的记录。") {
                    controller.clearRecent(through: through)
                }
            },
            .init(id: "delete-all-clips", title: "删除所有…", icon: "trash",
                  group: 3, enabled: controller.total > 0 || controller.migrationBackupCount > 0, destructive: true) {
                if confirm("删除所有剪贴板历史？", detail: "置顶记录及升级备份也会删除。") {
                    controller.clear(includePinned: true)
                }
            }
        ]
    }

    private static func confirm(_ title: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "删除").hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    private static func share(_ detail: ClipDetail, from view: NSView, controller: ClipboardController) {
        let item: Any
        switch detail.item.kind {
        case .text: item = detail.text
        case .image:
            guard let url = detail.assetURL, let image = NSImage(contentsOf: url) else {
                controller.feedback("图片附件不可用。")
                return
            }
            item = image
        case .files: return
        }
        let picker = NSSharingServicePicker(items: [item])
        let anchor = NSRect(x: view.bounds.maxX - 70, y: view.isFlipped ? view.bounds.maxY - 24 : view.bounds.minY + 24,
                            width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    private static func save(_ detail: ClipDetail, controller: ClipboardController) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        switch detail.item.kind {
        case .text:
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = "剪贴板文字.txt"
        case .image:
            guard let source = detail.assetURL, let type = UTType(filenameExtension: source.pathExtension) else {
                controller.feedback("图片附件不可用。")
                return
            }
            panel.allowedContentTypes = [type]
            panel.nameFieldStringValue = "剪贴板图片." + source.pathExtension
        case .files: return
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        DispatchQueue.global(qos: .utility).async {
            do {
                let data: Data
                if detail.item.kind == .text { data = Data(detail.text.utf8) }
                else if let source = detail.assetURL { data = try Data(contentsOf: source) }
                else { throw ClipboardError.missingAttachment }
                try data.write(to: destination, options: .atomic)
                DispatchQueue.main.async { controller.feedback("已保存文件。") }
            } catch {
                DispatchQueue.main.async { controller.feedback("保存失败：\(error.localizedDescription)") }
            }
        }
    }
}
