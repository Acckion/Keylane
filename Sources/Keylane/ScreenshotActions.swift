import AppKit
import KeylaneCore

enum ScreenshotActions {
    static func items(_ model: Model) -> [LauncherAction] {
        let library = model.screenshots
        let gridActions: [LauncherAction] = [
            .init(id: "screenshot-reset-zoom", title: "实际大小", icon: "1.magnifyingglass",
                  keys: ["⌘", "0"], group: 4, perform: library.resetZoom),
            .init(id: "screenshot-zoom-in", title: "放大网格", icon: "plus.magnifyingglass",
                  keys: ["⌘", "+"], group: 4, enabled: library.columns > ScreenshotLibrary.columnCounts.lowerBound,
                  perform: library.zoomIn),
            .init(id: "screenshot-zoom-out", title: "缩小网格", icon: "minus.magnifyingglass",
                  keys: ["⌘", "-"], group: 4, enabled: library.columns < ScreenshotLibrary.columnCounts.upperBound,
                  perform: library.zoomOut)
        ]
        guard let item = library.selected else { return gridActions }

        let delegate = NSApp.delegate as? Delegate
        var actions: [LauncherAction] = [
            .init(id: "screenshot-copy", title: "复制到剪贴板", icon: "clipboard", keys: ["↩"]) {
                copy(item, model: model)
            }
        ]
        if let delegate, let target = delegate.pasteTargetName {
            actions.append(.init(id: "screenshot-paste", title: "粘贴到 \(target)", icon: "clipboard",
                                 keys: ["⌘", "↩"], artwork: delegate.pasteTargetIcon) {
                perform(model) {
                    try library.copy(item)
                    delegate.pasteIntoPreviousApplication()
                }
            })
        }
        actions += [
            .init(id: "screenshot-open", title: "打开", icon: "doc", keys: ["⌘", "O"], group: 1) {
                withFile(item, model: model) {
                    guard NSWorkspace.shared.open(item.url) else { throw CocoaError(.fileReadUnknown) }
                    delegate?.hideLauncher()
                }
            },
            .init(id: "screenshot-open-with", title: "打开方式…", icon: "square.and.arrow.up",
                  keys: ["⇧", "⌘", "O"], group: 1) {
                withFile(item, model: model) { FileActionsWindow.shared.show(item.url, page: "open") }
            },
            .init(id: "screenshot-preview", title: "快速查看", icon: "eye", keys: ["⌘", "Y"], group: 1) {
                withFile(item, model: model) { FilePreview.shared.show(item.url) }
            },
            .init(id: "screenshot-reveal", title: "在访达中显示", icon: "folder", keys: ["⌥", "⌘", "O"], group: 1) {
                withFile(item, model: model) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            }
        ]
        if item.kind == .image {
            actions += [
                .init(id: "screenshot-annotate", title: "在「预览」中标注…", icon: "pencil",
                      keys: ["⇧", "⌘", "A"], group: 1) {
                    annotate(item, model: model)
                },
                .init(id: "screenshot-copy-ocr", title: "复制图片中的文字", icon: "clipboard",
                      keys: ["⌥", "⌘", "C"], group: 1) {
                    copyImageText(.ocr, item: item, model: model)
                },
                .init(id: "screenshot-copy-qr", title: "复制二维码文本", icon: "clipboard",
                      keys: ["⌥", "⇧", "⌘", "C"], group: 1) {
                    copyImageText(.qr, item: item, model: model)
                }
            ]
        }
        let pinned = library.pinnedIDs.contains(item.id)
        let mediaName = item.kind == .image ? "截图" : "录屏"
        actions += [
            .init(id: "screenshot-copy-path", title: "复制路径", icon: "clipboard",
                  keys: ["⌃", "⌘", "C"], group: 1) {
                perform(model) {
                    try library.copyPath(item)
                    delegate?.showLauncherFeedback("已复制路径", style: .success)
                }
            },
            .init(id: "screenshot-pin", title: (pinned ? "取消置顶" : "置顶") + mediaName,
                  icon: pinned ? "pin.slash" : "pin", keys: ["⌘", "."], group: 2) {
                perform(model) { try library.togglePin(item) }
            },
            .init(id: "screenshot-trash", title: "删除" + mediaName + "…", icon: "trash",
                  keys: ["⌃", "X"], group: 3, destructive: true) {
                confirmTrash(item, model: model)
            }
        ]
        return actions + gridActions
    }

    static func controls(_ model: Model, chooseFolders: @escaping () -> Void) -> [LauncherAction] {
        let library = model.screenshots
        var actions: [LauncherAction] = [
            .init(id: "screenshot-refresh", title: "刷新截图", icon: "arrow.clockwise", perform: library.refresh),
            .init(id: "screenshot-folders", title: "添加搜索文件夹…", icon: "folder.badge.plus", perform: chooseFolders),
            .init(id: "screenshot-settings", title: "截图设置…", icon: "gearshape",
                  perform: { model.openSettings(page: "screenshots") })
        ]
        if let item = library.selected {
            actions.append(.init(id: "screenshot-share", title: "分享…", icon: "square.and.arrow.up", group: 1) {
                withFile(item, model: model) { FileActionsWindow.shared.show(item.url, page: "share") }
            })
        }
        return actions
    }

    static func copy(_ item: ScreenshotMedia, model: Model) {
        perform(model) {
            try model.screenshots.copy(item)
            (NSApp.delegate as? Delegate)?.hideLauncher()
        }
    }

    private static func annotate(_ item: ScreenshotMedia, model: Model) {
        withFile(item, model: model) {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
                model.error = "找不到「预览」应用。"
                return
            }
            NSWorkspace.shared.open([item.url], withApplicationAt: app, configuration: .init()) { _, error in
                if let error { DispatchQueue.main.async { model.error = "无法打开「预览」：" + error.localizedDescription } }
            }
        }
    }

    private static func copyImageText(_ mode: ImageTextRecognition, item: ScreenshotMedia, model: Model) {
        Task { @MainActor in
            do {
                let copied = try await model.screenshots.copyImageText(mode, from: item)
                let message = mode == .qr ? "已复制二维码文本" : "已复制图片文字"
                (NSApp.delegate as? Delegate)?.showLauncherFeedback(copied ? message : mode.emptyMessage,
                                                                    style: copied ? .success : .failure)
            } catch {
                model.error = "识别截图失败：" + error.localizedDescription
            }
        }
    }

    private static func confirmTrash(_ item: ScreenshotMedia, model: Model) {
        guard let window = (NSApp.delegate as? Delegate)?.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "将「\(item.name)」移到废纸篓？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "移到废纸篓").hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn {
                perform(model) { try model.screenshots.moveToTrash(item) }
            }
        }
    }

    private static func withFile(_ item: ScreenshotMedia, model: Model, perform action: () throws -> Void) {
        perform(model) {
            try model.screenshots.validate(item)
            try action()
        }
    }

    private static func perform(_ model: Model, _ action: () throws -> Void) {
        do { try action() }
        catch {
            model.error = "截图操作失败：" + error.localizedDescription
            model.screenshots.refresh()
        }
    }
}
