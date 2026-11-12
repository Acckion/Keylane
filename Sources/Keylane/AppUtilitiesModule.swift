import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import KeylaneCore

enum AppUtilitiesModule {
    static func make(model: Model) -> LauncherModule {
        let capture = PermissionFeature("screenCapture.enabled", authorization: .screenCapture, observeImmediately: false)
        let camera = CameraPreviewWindow()
        let cameraPermission = PermissionFeature("cameraPreview.enabled", authorization: .camera, observeImmediately: false)
        var cameraChanges: AnyCancellable?
        var pendingCapture: DispatchWorkItem?
        return LauncherModule(id: .init(rawValue: "keylane.app-utilities"), title: "Keylane 工具",
                              symbol: "wrench.and.screwdriver", commands: [
            command("export-settings", "导出 Keylane 设置", "square.and.arrow.up",
                    ["Export Settings", "设置备份"]) { presentSettingsExport() },
            command("view-release-notes", "查看 Keylane 更新日志", "doc.text",
                    ["Changelog", "Release Notes", "版本记录"]) {
                NSWorkspace.shared.open(KeylaneReleaseCheck.releasesURL)
                (NSApp.delegate as? Delegate)?.hideLauncher()
            },
            command("check-for-updates", "检查 Keylane 更新", "arrow.clockwise",
                    ["Check for Updates", "检查更新"]) { [weak model] in
                guard let model, let delegate = NSApp.delegate as? Delegate else { return }
                model.settingsPage = "about"
                delegate.hideLauncher()
                delegate.showSettings()
                model.updates.check()
            },
            .init(declaration: .init(id: .init(rawValue: "screenshot"), title: "Screenshot / 截图", detail: "截取屏幕区域",
                                     symbol: "camera.viewfinder", keywords: ["屏幕截取", "截屏"], destination: .action,
                                     settingsPage: "keylane.app-utilities"),
                  settingsEnabled: Binding(get: { capture.enabled }, set: capture.setEnabled),
                  permission: capture, execute: { _ in
                      (NSApp.delegate as? Delegate)?.hideLauncher()
                      pendingCapture?.cancel()
                      let task = DispatchWorkItem {
                          pendingCapture = nil
                          if capture.available { SystemTools.shared.screenshot() }
                      }
                      pendingCapture = task
                      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
                  }),
            .init(declaration: .init(id: .init(rawValue: "show-camera"), title: "显示相机", detail: "实时相机预览",
                                     symbol: "camera", keywords: ["Show Camera", "Camera Preview", "摄像头", "相机预览"],
                                     destination: .action, settingsPage: "keylane.app-utilities"),
                  settingsEnabled: Binding(get: { cameraPermission.enabled }, set: cameraPermission.setEnabled),
                  permission: cameraPermission, execute: { [weak model] _ in
                      camera.show(activation: model?.windowActivationBehavior ?? .systemDefault)
                  })
        ], services: [.init(start: {
            capture.startObserving()
            cameraPermission.startObserving()
            cameraChanges = cameraPermission.updates.receive(on: DispatchQueue.main).sink {
                if !cameraPermission.available { camera.close() }
            }
        }, stop: {
            cameraChanges?.cancel()
            cameraChanges = nil
            capture.stopObserving()
            cameraPermission.stopObserving()
            pendingCapture?.cancel()
            pendingCapture = nil
            SystemTools.shared.stopScreenshot()
            camera.close()
        })], searchUpdates: [capture.updates, cameraPermission.updates],
           shortcutSettingsUpdates: [capture.settingsUpdates, cameraPermission.settingsUpdates])
    }

    private static func command(_ id: String, _ title: String, _ symbol: String, _ keywords: [String],
                                action: @escaping () -> Void) -> LauncherModule.Command {
        .init(declaration: .init(id: .init(rawValue: id), title: title, detail: "Keylane 工具", symbol: symbol,
                                 keywords: keywords, destination: .action), execute: { _ in action() })
    }

    private static func presentSettingsExport() {
        (NSApp.delegate as? Delegate)?.hideLauncher()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "导出 Keylane 设置"
        panel.message = "保存启动器、外观和键盘偏好。"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Keylane-settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SettingsExport.data(defaults: .standard).write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "无法导出 Keylane 设置"
            alert.runModal()
        }
    }
}
