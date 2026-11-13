import AppKit
import KeylaneCore
import UniformTypeIdentifiers

enum ClipboardActions {
    static func copy(_ controller: ClipboardController, format: ClipboardReplayFormat = .original) {
        let id = controller.selectedID
        let copied = controller.copySelected(format: format)
        if copied { controller.recordReplay(of: id) }
        let message = copied ? (format == .plainText ? "已复制纯文本" : "已复制到剪贴板") : controller.status
        (NSApp.delegate as? Delegate)?.showLauncherFeedback(message, style: copied ? .success : .failure)
    }

    static func submit(_ controller: ClipboardController, alternate: Bool = false) {
        guard !SearchField.isComposing else { return }
        let delegate = NSApp.delegate as? Delegate
        if let delegate, delegate.pasteTargetName != nil, (controller.primaryAction == .paste) != alternate {
            delegate.pasteClipboard()
        } else {
            copy(controller)
        }
    }

    private static func formatTitle(_ format: ClipboardReplayFormat) -> String {
        switch format {
        case .original, .preferred: return "原始格式"
        case .plainText: return "纯文本"
        case .pngFromTIFF: return "PNG（从 TIFF 转换）"
        case .representation(let type):
            switch type {
            case UTType.rtf.identifier: return "RTF"
            case UTType.flatRTFD.identifier: return "RTFD"
            case UTType.html.identifier: return "HTML"
            case UTType.url.identifier: return "链接"
            default: return UTType(type)?.preferredFilenameExtension?.uppercased() ?? type
            }
        }
    }

    static func items(_ model: Model) -> [LauncherAction] {
        let controller = model.clipboard
        guard let item = controller.items.first(where: { $0.id == controller.selectedID }) else { return [] }
        let detail = controller.selectedDetail
        let text = detail?.text ?? ""
        let canEdit = item.category.canEditText
        let delegate = NSApp.delegate as? Delegate
        let targetName = delegate?.pasteTargetName
        let targetIcon = delegate?.pasteTargetIcon
        let link = item.webURL
        let quicklink = link ?? (item.category == .email ? ClipboardCategory.emailURL(in: text) : nil)
        let hasImage = item.category == .image || (detail?.files.count == 1 &&
            detail?.files.first.map(ClipboardController.isImageFile) == true)

        func feedback(_ success: Bool, _ message: String) {
            delegate?.showLauncherFeedback(message, style: success ? .success : .failure)
        }

        var actions: [LauncherAction] = []
        let pasteIsPrimary = targetName != nil && controller.primaryAction == .paste
        let copyAction = LauncherAction(id: "copy-clip", title: "复制到剪贴板", icon: "clipboard",
                                       keys: pasteIsPrimary ? ["⌘", "↩"] : ["↩"], perform: { copy(controller) })
        if !pasteIsPrimary { actions.append(copyAction) }
        if let targetName {
            actions.append(.init(id: "paste-clip", title: "粘贴到 \(targetName)", icon: "doc.on.clipboard",
                                 keys: pasteIsPrimary ? ["↩"] : ["⌘", "↩"], artwork: targetIcon,
                                 perform: { delegate?.pasteClipboard() }))
        }
        if pasteIsPrimary { actions.append(copyAction) }
        if targetName != nil {
            actions.append(.init(id: "paste-keep-open-clip", title: "粘贴并保持窗口打开", icon: "doc.on.clipboard",
                                 keys: ["⌥", "↩"], artwork: targetIcon, perform: { delegate?.pasteClipboard(keepOpen: true) }))
        }
        let formats = controller.availableReplayFormats
        if !formats.isEmpty {
            let choices = [.original] + formats
            if targetName != nil {
                let pasteFormats = choices.enumerated().map { index, format in
                    LauncherAction(id: "paste-format-\(index)", title: formatTitle(format), icon: "clipboard") {
                        delegate?.pasteClipboard(format: format)
                    }
                }
                actions.append(.init(id: "paste-as-clip", title: "粘贴为…", icon: "text.insert",
                                     keys: ["⌥", "⌘", "↩"], artwork: targetIcon,
                                     submenu: .init(title: "粘贴为…", items: pasteFormats)))
            }
            let copyFormats = choices.enumerated().map { index, format in
                LauncherAction(id: "copy-format-\(index)", title: formatTitle(format), icon: "clipboard") {
                    copy(controller, format: format)
                }
            }
            actions.append(.init(id: "copy-as-clip", title: "复制为…", icon: "clipboard",
                                 submenu: .init(title: "复制为…", items: copyFormats)))
        }
        if canEdit, formats.contains(.plainText) {
            if let targetName {
                actions.append(.init(id: "paste-plain-clip", title: "以纯文本粘贴到 \(targetName)", icon: "text.insert",
                                     keys: ["⌃", "⌘", "↩"], artwork: targetIcon,
                                     perform: { delegate?.pasteClipboard(format: .plainText) }))
            } else {
                actions.append(.init(id: "copy-plain-clip", title: "复制为纯文本", icon: "text.alignleft",
                                     perform: { copy(controller, format: .plainText) }))
            }
        }

        if let link {
            actions.append(.init(id: "open-clip-link", title: "在浏览器中打开", icon: "globe", keys: ["⌘", "O"], group: 1) {
                if !NSWorkspace.shared.open(link) { feedback(false, "无法在浏览器中打开链接。") }
            })
        }
        if let color = item.color {
            let title = "复制颜色为…"
            let formats = ClipboardColor.Format.allCases.map { format in
                LauncherAction(id: "copy-color-\(format)", title: format.rawValue, icon: "",
                               value: color.formatted(as: format), perform: {
                    let copied = controller.copyColor(color, as: format)
                    feedback(copied, copied ? "已复制颜色" : controller.status)
                })
            }
            actions.append(.init(id: "copy-color-as", title: title, icon: "clipboard", keys: ["⌥", "⌘", "C"],
                                 submenu: .init(title: title, items: formats), group: 1))
        }

        if let detail {
            actions.append(.init(id: "share-clip", title: "分享…", icon: "square.and.arrow.up", group: 1) {
                if canEdit {
                    controller.share(link.map { $0 as Any } ?? text)
                } else {
                    withFiles(detail, controller: controller, failure: feedback) { files in
                        FileActionsWindow.shared.show(files.urls, page: "share", retaining: files, owner: .clipboard)
                    }
                }
            })
        }
        if canEdit {
            actions.append(.init(id: "edit-clip", title: "编辑文本", icon: "pencil", keys: ["⌘", "E"],
                                 group: 1, enabled: !text.isEmpty, perform: controller.editSelectedText))
        }
        actions.append(.init(id: "rename-clip", title: "重命名记录…", icon: "rectangle.dashed",
                             keys: ["⇧", "⌘", "E"], group: 1, perform: controller.renameSelected))
        actions.append(.init(id: "ai-clip", title: canEdit ? "发送给 AI 聊天" : "附加到 AI 聊天",
                             icon: "sparkles", keys: canEdit ? ["⌘", "J"] : ["⌃", "⌘", "A"],
                             group: 1, enabled: false))

        if let detail, !canEdit {
            actions += fileActions(detail, controller: controller, hasImage: hasImage, feedback: feedback)
        }
        actions.append(.init(id: "pin-clip", title: item.pinned ? "取消置顶" : "置顶记录", icon: "pin",
                             keys: ["⌘", "."], group: 1, perform: controller.pinSelected))
        if !text.isEmpty, model.launcherModules?.isModuleEnabled(.init(rawValue: "keylane.snippets")) == true {
            actions.append(.init(id: "snippet-clip", title: "存为文字片段", icon: "text.badge.plus",
                                 keys: ["⌘", "S"], group: 2) { [weak model] in
                model?.runCommand(SnippetsModule.createCommandID, origin: .menu, arguments: [text])
            })
        }
        if let quicklink, model.launcherModules?.isModuleEnabled(.init(rawValue: "keylane.links")) == true {
            let title = link?.host() ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
            actions.append(.init(id: "quicklink-clip", title: "存为快捷链接", icon: "link",
                                 keys: ["⇧", "⌘", "S"], group: 2) { [weak model] in
                if let model { QuicklinksModule.create(from: quicklink, title: title, model: model) }
            })
        } else if let detail {
            actions.append(.init(id: "save-clip", title: "存为文件…", icon: "arrow.down.document",
                                 keys: ["⌥", "⇧", "⌘", "S"], group: 2) {
                controller.export(detail) { result in
                    switch result {
                    case .success: feedback(true, "已保存文件")
                    case .failure(let error): feedback(false, error.localizedDescription)
                    }
                }
            })
        }
        if let detail, hasImage {
            actions += [
                .init(id: "ocr-clip", title: "复制图片中的文字", icon: "clipboard", keys: ["⌥", "⌘", "C"], group: 2) {
                    controller.copyImageText(.ocr, from: detail, completion: feedback)
                },
                .init(id: "qr-clip", title: "复制二维码文本", icon: "clipboard", keys: ["⌥", "⇧", "⌘", "C"], group: 2) {
                    controller.copyImageText(.qr, from: detail, completion: feedback)
                }
            ]
        }
        actions += [
            .init(id: "delete-clip", title: "删除记录", icon: "trash", keys: ["⌃", "X"],
                  group: 3, destructive: true, perform: controller.removeSelected),
            .init(id: "delete-recent-clips", title: "删除最近的记录…", icon: "clock", keys: ["⇧", "⌘", "X"],
                  group: 3, destructive: true, perform: { controller.confirmHistoryRemoval(recent: true) }),
            .init(id: "delete-all-clips", title: "删除全部记录", icon: "trash", keys: ["⌃", "⇧", "X"],
                  group: 3, destructive: true, perform: { controller.confirmHistoryRemoval(recent: false) })
        ]
        return actions
    }

    private static func fileActions(_ detail: ClipDetail, controller: ClipboardController, hasImage: Bool,
                                    feedback: @escaping (Bool, String) -> Void) -> [LauncherAction] {
        var actions: [LauncherAction] = [
            .init(id: "open-clip-file", title: "打开方式…", icon: "app", keys: ["⌘", "O"], group: 1) {
                withFiles(detail, controller: controller, failure: feedback) { files in
                    FileActionsWindow.shared.show(files.urls, page: "open", retaining: files, owner: .clipboard)
                }
            },
            .init(id: "reveal-clip-file", title: "在访达中显示", icon: "folder", keys: ["⇧", "⌘", "O"], group: 1) {
                withFiles(detail, controller: controller, failure: feedback) { files in
                    NSWorkspace.shared.activateFileViewerSelecting(files.urls)
                }
            }
        ]
        if hasImage {
            actions.append(.init(id: "annotate-clip", title: "在「预览」中标注…", icon: "pencil",
                                 keys: ["⇧", "⌘", "A"], group: 1) {
                guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
                    feedback(false, "找不到「预览」应用。")
                    return
                }
                controller.export(detail, forAnnotation: true) { result in
                    switch result {
                    case .success(let copies):
                        NSWorkspace.shared.open(copies, withApplicationAt: app, configuration: .init()) { _, error in
                            if let error {
                                DispatchQueue.main.async { feedback(false, "标注副本已保存。无法打开「预览」：\(error.localizedDescription)") }
                            }
                        }
                    case .failure(let error): feedback(false, error.localizedDescription)
                    }
                }
            })
        }
        actions.append(.init(id: "preview-clip-file", title: "快速查看", icon: "eye", keys: ["⌘", "Y"], group: 1) {
            withFiles(detail, controller: controller, failure: feedback) { files in
                FilePreview.shared.show(files.urls, retaining: files, owner: .clipboard)
            }
        })
        return actions
    }

    private static func withFiles(_ detail: ClipDetail, controller: ClipboardController,
                                  failure: (Bool, String) -> Void, perform: (ClipboardFiles) -> Void) {
        let files = controller.files(for: detail)
        guard files.isAvailable else {
            failure(false, "文件已移走或删除。")
            return
        }
        perform(files)
    }
}
