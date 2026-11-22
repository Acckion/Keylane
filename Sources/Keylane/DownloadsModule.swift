import AppKit
import Combine
import SwiftUI
import KeylaneCore

enum DownloadsModule {
    static func make(model: Model) -> LauncherModule {
        let controller = model.downloads
        let settingsID = "keylane.downloads"
        let commandID = CommandID(rawValue: "search-downloads")
        let pageID = PageID(rawValue: "Downloads")
        let permission = PermissionFeature("downloads.optIn", authorization: .init(
            check: { controller.authorized },
            request: { controller.chooseFolder($0) },
            guidance: "启用时选择下载文件夹，授权成功后才会开始读取。"), observeImmediately: false)
        var changes: AnyCancellable?
        let commands: [LauncherModule.Command] = [
            .init(declaration: .init(id: commandID, title: "下载", detail: "搜索、预览和管理下载文件", symbol: "arrow.down.circle",
                                     keywords: ["Downloads", "下载管理", "最近下载"], destination: .page(pageID), settingsPage: settingsID), permission: permission)
        ]
        let page = LauncherPage(id: pageID, placeholder: "搜索下载文件…", badge: ("下载", "arrow.down.circle"), actionTitle: "下载操作",
            contentPlacement: .underChrome,
            content: { AnyView(DownloadsView(controller: controller)) },
            queryChanged: { controller.query = $0 },
            move: controller.move,
            submit: controller.openSelected,
            actionSelectionID: { controller.selectedID },
            actionContextTitle: { controller.selected?.url.lastPathComponent },
            primaryTitle: { "打开" }, primaryEnabled: { controller.selected != nil },
            actions: { actions(controller, model: model) },
            updates: Publishers.Merge4(ViewObservation.changes(controller.$files), ViewObservation.changes(controller.$selectedID), ViewObservation.changes(controller.$operationError), ViewObservation.changes(controller.$scanError)).eraseToAnyPublisher(),
            enter: { controller.query = $0; controller.refresh(); return nil },
            resume: { controller.refresh() },
            badgeActions: { [
                .init(id: "downloads-refresh", title: "刷新", icon: "arrow.clockwise", perform: controller.refresh),
                .init(id: "downloads-settings", title: "下载设置…", icon: "gearshape", perform: { model.openSettings(page: settingsID) })
            ] }, actionShortcutsEnabled: true)
        let anchor = SettingsItem(id: "downloads.folder", page: settingsID, title: "下载文件夹", keywords: "下载 Downloads 目录 自动 暂存架")
        return .init(id: .init(rawValue: settingsID), title: "下载", symbol: "arrow.down.circle", commands: commands, pages: [page],
            settings: [.init(id: settingsID, title: "下载", symbol: "arrow.down.circle", subtitle: "在 Keylane 中管理本机下载文件。", order: 86,
                             items: [anchor], titlebar: permission.titlebar("启用下载"), content: {
                AnyView(DownloadsPreferences(controller: controller, model: model, commands: commands, anchor: anchor))
            })], services: [.init(start: { [weak model] in
                controller.addToShelf = { [weak model] in model?.dropShelf.addFiles($0) ?? false }
                permission.startObserving(); controller.setEnabled(permission.available)
                changes = Publishers.Merge(permission.updates, ViewObservation.changes(controller.$folder)).receive(on: DispatchQueue.main).sink {
                    permission.recheck(); controller.setEnabled(permission.available)
                }
            }, stop: {
                changes?.cancel(); changes = nil; permission.stopObserving(); controller.setEnabled(false); controller.addToShelf = nil
            })])
    }
    private static func actions(_ controller: DownloadsController, model: Model) -> [LauncherAction] {
        let dismissError: [LauncherAction] = controller.operationError.isEmpty ? [] : [
            .init(id: "download-dismiss-error", title: "关闭操作错误提示", icon: "xmark.circle", group: 3,
                  perform: controller.dismissOperationError)
        ]
        guard controller.selected != nil else { return dismissError }
        return dismissError + [
            .init(id: "download-open", title: "打开", icon: "arrow.up.forward.app", perform: controller.openSelected),
            .init(id: "download-shelf", title: "加入暂存架", icon: "tray.and.arrow.down", shortcut: .init("s", modifiers: [.command, .shift]), perform: controller.sendSelectedToShelf),
            .init(id: "download-reveal", title: "在 Finder 中显示", icon: "folder", group: 1, perform: {
                controller.withSelected { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
            }),
            .init(id: "download-copy", title: "复制文件", icon: "clipboard", shortcut: .init("c", modifiers: .command), group: 1, perform: {
                controller.withSelected { url in NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([url as NSURL]) }
            }),
            .init(id: "download-copy-path", title: "复制路径", icon: "link", group: 1, perform: {
                controller.withSelected { url in NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) }
            }),
            .init(id: "download-trash", title: "移到废纸篓…", icon: "trash", group: 2, destructive: true, perform: {
                guard let file = controller.selected, let window = (NSApp.delegate as? Delegate)?.window, window.attachedSheet == nil else { return }
                let alert = NSAlert(); alert.messageText = "将「\(file.url.lastPathComponent)」移到废纸篓？"
                alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "移到废纸篓").hasDestructiveAction = true
                alert.beginSheetModal(for: window) { response in
                    // Recheck selection so an asynchronous refresh cannot change the deletion target.
                    guard response == .alertSecondButtonReturn, controller.selectedID == file.id else { return }
                    controller.withSelected { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }; controller.refresh()
                }
            })
        ]
    }
}

private struct DownloadsView: View {
    @ObservedObject var controller: DownloadsController
    var body: some View {
        ResultDetailLayout(hasResults: !controller.results.isEmpty) {
            VStack(spacing: 0) {
                if !controller.error.isEmpty { Text(controller.error).foregroundStyle(.secondary).font(.caption).padding() }
                SelectableResultList(selection: controller.selectedID, query: controller.query, firstResult: controller.results.first?.id) {
                    ResultListSection(title: "下载文件", isFirst: true) {
                        ForEach(controller.results) { file in
                            ResultListButton(id: file.id, action: { controller.selectedID = file.id }) {
                                ResultListRow(selected: file.id == controller.selectedID) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path)).resizable().scaledToFit().frame(width: 28, height: 28)
                                } content: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HighlightedResultText(text: file.url.lastPathComponent, query: controller.query).font(VisualStyle.rowText).lineLimit(1)
                                        Text(file.modified.formatted(date: .abbreviated, time: .shortened) + (file.directory ? " · 文件夹" : " · " + ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } detail: { FileSearchDetail(url: controller.selected?.url) }
        emptyState: { ResultDetailEmptyState(title: "没有匹配的下载文件", message: controller.error.isEmpty ? "仅显示下载文件夹第一层的文件；临时下载文件不会显示。" : controller.error) }
    }
}

private struct DownloadsPreferences: View {
    @ObservedObject var controller: DownloadsController
    let model: Model
    let commands: [LauncherModule.Command]
    let anchor: SettingsItem
    var body: some View {
        SettingsPageSections {
            SettingsCard(anchor: anchor) {
                DownloadsFolderSettingRow(controller: controller, folderPath: controller.folder?.path)
                Divider()
                SettingsRow("新下载自动加入暂存架", detail: "默认关闭。开启后，新出现且写入稳定的文件会加入暂存架；已有文件和未完成下载不会自动加入。") {
                    Toggle("自动加入", isOn: $controller.autoShelf).labelsHidden()
                }
                if !controller.error.isEmpty { SettingsDescription(controller.error) }
            }
            SettingsSectionTitle(title: "命令")
            ExtensionCommandPreferences(model: model, commands: commands)
        }
    }
}


struct DownloadsFolderSettingRow: View {
    let controller: DownloadsController
    let folderPath: String?

    var body: some View {
        SettingsRow("下载文件夹", detail: folderPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "尚未选择文件夹。") {
            Button("选择文件夹…") { controller.chooseFolder() }
        }
    }
}
