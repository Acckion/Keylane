import AppKit
import SwiftUI
import KeylaneCore

/// Non-activating panels preserve keyboard focus in the user's current app.
final class FocusWindows {
    private unowned let controller: FocusController
    private var bar: NSPanel?
    private var toast: NSPanel?
    private var blocked: NSPanel?
    private var blockedID: String?
    private var edges: [NSPanel] = []
    private var dismissal: DispatchWorkItem?
    private var glowDismissal: DispatchWorkItem?
    init(controller: FocusController) { self.controller = controller }

    func update() {
        if let target = controller.blockedTarget, controller.session?.paused == false,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target.id {
            if blockedID != target.id {
                blocked?.close()
                let overlay = makePanel(size: NSSize(width: 420, height: 180))
                overlay.contentView = NSHostingView(rootView: FocusBlockedView(controller: controller, name: target.name))
                if let screen = NSScreen.main { overlay.setFrameOrigin(NSPoint(x: screen.frame.midX - 210, y: screen.frame.midY - 90)) }
                blocked = overlay; blockedID = target.id
            }
            blocked?.orderFrontRegardless()
        } else { blocked?.close(); blocked = nil; blockedID = nil }
        guard controller.session != nil, !controller.preferences.inMenuBar else {
            bar?.orderOut(nil); return
        }
        if toast?.isVisible == true { bar?.orderOut(nil); return }
        if bar == nil {
            let panel = makePanel(size: NSSize(width: 360, height: 66))
            panel.isMovableByWindowBackground = true
            panel.contentView = NSHostingView(rootView: FocusBar(controller: controller))
            position(panel, offset: 36)
            bar = panel
        }
        bar?.orderFrontRegardless()
    }
    func notify(title: String, detail: String, success: Bool) {
        dismissal?.cancel(); glowDismissal?.cancel()
        if controller.preferences.playSound { NSSound(named: success ? "Glass" : "Basso")?.play() }
        toast?.close()
        let panel = makePanel(size: NSSize(width: 440, height: 76))
        panel.contentView = NSHostingView(rootView: FocusNotice(controller: controller, title: title, detail: detail, success: success, target: success ? nil : controller.blockedTarget, sessionID: controller.session?.id))
        position(panel, offset: 6)
        toast = panel; bar?.orderOut(nil); panel.orderFrontRegardless()
        let dismiss = DispatchWorkItem { [weak self] in self?.toast?.orderOut(nil); self?.update() }
        dismissal = dismiss; DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: dismiss)
        edges.forEach { $0.close() }; edges = []
        for screen in NSScreen.screens {
            let edge = makePanel(size: screen.frame.size)
            edge.setFrame(screen.frame, display: false)
            edge.ignoresMouseEvents = true
            edge.contentView = NSHostingView(rootView: FocusEdgeGlow(success: success))
            edge.orderFrontRegardless(); edges.append(edge)
        }
        let fade = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let oldEdges = self.edges; self.edges = []
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.6
                oldEdges.forEach { $0.animator().alphaValue = 0 }
            } completionHandler: { oldEdges.forEach { $0.close() } }
        }
        glowDismissal = fade; DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: fade)
    }
    func dismissNotice() { dismissal?.cancel(); toast?.orderOut(nil) }
    func close() {
        dismissal?.cancel(); glowDismissal?.cancel()
        bar?.close(); bar = nil; toast?.close(); toast = nil
        blocked?.close(); blocked = nil; blockedID = nil
        edges.forEach { $0.close() }; edges = []
    }
    private func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.backgroundColor = .clear; panel.isOpaque = false
        panel.hasShadow = false; panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }
    private func position(_ panel: NSPanel, offset: CGFloat) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - panel.frame.width / 2,
                                     y: screen.visibleFrame.maxY - panel.frame.height - offset))
    }
}

private struct FocusBar: View {
    @ObservedObject var controller: FocusController
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "target").foregroundStyle(.mint).font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.session?.configuration.goal ?? "专注").font(.headline).lineLimit(1)
                Text(controller.status).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !controller.browserMessage.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(controller.browserMessage)
            }
            Button {
                if controller.session?.paused == true { controller.resume() } else { controller.pause() }
            } label: { Image(systemName: controller.session?.paused == true ? "play.fill" : "pause.fill") }
                .help(controller.session?.paused == true ? "恢复专注" : "暂停专注")
            Button { controller.finish(completed: true) } label: { Image(systemName: "checkmark") }.help("完成专注")
            Menu {
                Button("编辑专注") { controller.edit?() }
                Menu("暂停") {
                    ForEach([1, 3, 5, 10, 15, 30], id: \.self) { minutes in
                        Button("\(minutes) 分钟") { controller.pause(minutes: minutes) }
                    }
                }
                Button("重新开始") { controller.restart() }
                Button("取消专注") { controller.finish(completed: false) }
                Divider()
                Button("移到菜单栏") { controller.preferences.inMenuBar = true }
                Button("专注设置…") { controller.openSettings?() }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).frame(width: 20)
        }
        .buttonStyle(.plain).padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.15)))
        .padding(3)
    }
}
private struct FocusNotice: View {
    @ObservedObject var controller: FocusController
    let title: String
    let detail: String
    let success: Bool
    let target: FocusApplication?
    let sessionID: UUID?
    var body: some View {
        HStack(spacing: 13) {
            if !success, let target,
               let url = controller.applicationURL(target.id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
            } else { Image(systemName: success ? "target" : "exclamationmark.shield").font(.title2) }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).lineLimit(1)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !success, let target, sessionID != nil, controller.session?.id == sessionID,
               controller.session?.paused == false, controller.preferences.snoozeMinutes > 0 {
                Button("临时放行") { controller.snooze(target: target) }.buttonStyle(.bordered)
                    .help("放行 \(controller.preferences.snoozeMinutes) 分钟")
            }
        }.padding(17).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .background((success ? Color.green : .orange).opacity(0.16), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.22)))
            .padding(3)
    }
}
private struct FocusEdgeGlow: View {
    let success: Bool
    var body: some View {
        let color: Color = success ? .green : Color(red: 1, green: 0.72, blue: 0.16)
        ZStack {
            Rectangle().strokeBorder(color.opacity(0.55), lineWidth: 7)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                Rectangle().strokeBorder(color.opacity(0.30), lineWidth: 30).blur(radius: 22)
                Rectangle().strokeBorder(color.opacity(0.12), lineWidth: 70).blur(radius: 32)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct FocusBlockedView: View {
    @ObservedObject var controller: FocusController
    let name: String
    var body: some View {
        VStack(spacing: 14) {
            Label(name + " 已被屏蔽", systemImage: "lock.shield").font(.headline)
            Text("保存工作后切换应用，或暂停本次专注。").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("暂停专注") { controller.pause() }
                if controller.preferences.snoozeMinutes > 0 {
                    Button("临时放行 \(controller.preferences.snoozeMinutes) 分钟") { controller.snooze() }
                }
            }.buttonStyle(.bordered)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.orange.opacity(0.5)))
            .padding(4)
    }
}
