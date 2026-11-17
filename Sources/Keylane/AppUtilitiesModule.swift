import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import KeylaneCore

enum AppUtilitiesModule {
    static let cameraPageID = PageID(rawValue: "CameraPreview")

    static func make(model: Model) -> LauncherModule {
        let releaseNotes = ReleaseNotesLauncher(model: model)
        let capture = PermissionFeature("screenCapture.enabled", authorization: .screenCapture, observeImmediately: false)
        let camera = model.cameraPreview
        let cameraPermission = PermissionFeature("cameraPreview.enabled", authorization: .camera, observeImmediately: false)
        var cameraChanges: AnyCancellable?
        var pendingCapture: DispatchWorkItem?
        return LauncherModule(id: .init(rawValue: "keylane.app-utilities"), title: "Keylane 工具",
                              symbol: "wrench.and.screwdriver", commands: [
            command("export-settings", "导出 Keylane 设置", "square.and.arrow.up",
                    ["Export Settings", "设置备份"]) { ConfigurationTransfer.export() },
            .init(declaration: .init(id: .init(rawValue: "view-release-notes"), title: "查看 Keylane 更新日志",
                                     detail: "浏览版本记录", symbol: "doc.text",
                                     keywords: ["Changelog", "Release Notes", "版本记录"],
                                     destination: .page(ReleaseNotesLauncher.listID))),
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
                                     destination: .page(cameraPageID), settingsPage: "keylane.app-utilities"),
                  settingsEnabled: Binding(get: { cameraPermission.enabled }, set: cameraPermission.setEnabled),
                  permission: cameraPermission, execute: { _ in camera.meeting = nil })
        ], pages: releaseNotes.pages + [cameraPage(model: model, permission: cameraPermission)], services: [.init(start: { [weak model] in
            capture.startObserving()
            cameraPermission.startObserving()
            cameraChanges = cameraPermission.updates.receive(on: DispatchQueue.main).sink {
                if !cameraPermission.available {
                    camera.stop()
                    if model?.pageID == cameraPageID { model?.pageID = .root }
                }
            }
        }, stop: {
            cameraChanges?.cancel()
            cameraChanges = nil
            capture.stopObserving()
            cameraPermission.stopObserving()
            pendingCapture?.cancel()
            pendingCapture = nil
            SystemTools.shared.stopScreenshot()
            camera.stop()
        })], searchUpdates: [capture.updates, cameraPermission.updates],
           shortcutSettingsUpdates: [capture.settingsUpdates, cameraPermission.settingsUpdates])
    }

    private static func cameraPage(model: Model, permission: PermissionFeature) -> LauncherPage {
        let camera = model.cameraPreview
        let back: () -> Void = { [weak model] in
            let page = camera.meeting?.returnPage ?? .root
            model?.pageID = model?.launcherModules?.page(page) == nil ? .root : page
        }
        let start = { if permission.available { camera.start() } }
        let takePhoto: (CameraPreview.PhotoDestination) -> Void = { [weak model] destination in
            guard permission.available, let model else { return }
            camera.takePhoto(destination, aspect: VisualStyle.launcherWidth / model.launcherHeight)
        }
        let submit: () -> Void = { [weak model] in
            guard let meeting = camera.meeting else { takePhoto(.clipboard); return }
            camera.stop(completion: meeting.join)
            model?.pageID = .root
            (NSApp.delegate as? Delegate)?.hideLauncher()
        }
        return .init(
            id: cameraPageID, placeholder: "", badge: ("相机预览", "camera"), contentPlacement: .form,
            content: { AnyView(CameraPreviewPage(camera: camera, back: back)) },
            leave: { camera.stop() }, back: back,
            submit: submit, shortcutSubmit: submit,
            primaryTitle: { camera.meeting == nil ? "拍摄并拷贝到剪贴板" : "加入会议" },
            primaryEnabled: { camera.meeting != nil || camera.canTakePhoto },
            actions: { cameraActions(camera, takePhoto: takePhoto) },
            updates: Publishers.MergeMany([
                camera.$meeting.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                ViewObservation.changes(camera.$state),
                ViewObservation.changes(camera.$takingPhoto),
                ViewObservation.changes(camera.$devices),
                ViewObservation.changes(camera.$deviceID),
                ViewObservation.changes(camera.$mirrored),
                ViewObservation.changes(camera.$shutterEnabled)
            ]).eraseToAnyPublisher(),
            enter: { _ in start(); return nil }, resume: start,
            maximumActionWidth: 330, fullBleed: true, submitWithReturn: true
        )
    }

    private static func cameraActions(_ camera: CameraPreview,
                                      takePhoto: @escaping (CameraPreview.PhotoDestination) -> Void) -> [LauncherAction] {
        let cameras = camera.devices.map { device in
            LauncherAction(id: device.uniqueID, title: device.localizedName, icon: "camera",
                           value: device.uniqueID == camera.deviceID && camera.state == .running ? "当前" : nil,
                           enabled: device.uniqueID != camera.deviceID || camera.state == .failed,
                           perform: { camera.selectCamera(device) })
        }
        return [
            .init(id: "camera-copy-photo", title: "拍摄并拷贝到剪贴板", icon: "clipboard",
                  enabled: camera.canTakePhoto, perform: { takePhoto(.clipboard) }),
            .init(id: "camera-save-desktop", title: "保存到桌面", icon: "square.and.arrow.down",
                  enabled: camera.canTakePhoto, perform: { takePhoto(.desktop) }),
            .init(id: "camera-mirror", title: "切换镜像", icon: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                  value: camera.mirrored ? "已开启" : "已关闭", group: 1, perform: camera.toggleMirroring),
            .init(id: "camera-switch", title: "切换摄像头", icon: "arrow.triangle.2.circlepath.camera",
                  submenu: .init(title: "切换摄像头", items: cameras), group: 1,
                  enabled: !camera.takingPhoto && camera.state != .starting && cameras.contains(where: \.enabled)),
            .init(id: "camera-shutter", title: camera.shutterEnabled ? "禁用快门声音" : "启用快门声音",
                  icon: camera.shutterEnabled ? "speaker.slash" : "speaker.wave.2", group: 1,
                  perform: camera.toggleShutter)
        ]
    }

    private static func command(_ id: String, _ title: String, _ symbol: String, _ keywords: [String],
                                action: @escaping () -> Void) -> LauncherModule.Command {
        .init(declaration: .init(id: .init(rawValue: id), title: title, detail: "Keylane 工具", symbol: symbol,
                                 keywords: keywords, destination: .action), execute: { _ in action() })
    }

}
