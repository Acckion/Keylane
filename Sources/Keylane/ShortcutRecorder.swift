import SwiftUI
import AppKit
import KeylaneCore

struct ShortcutRecorder: View {
    let shortcut: Shortcut?
    var compact = false
    var title = "快捷键"
    var icon: AnyView = AnyView(Image(systemName: "keyboard"))
    let changed: (Shortcut?) -> Void
    @State private var recording = false
    @State private var hovering = false
    @State private var clearHovered = false
    @State private var monitor: Any?
    @State private var draft: Shortcut?
    @State private var liveModifiers: [String] = []
    @State private var keyHeld = false
    var body: some View {
        HStack(spacing: 4) {
            Button { start() } label: {
                recorderLabel.font(.system(size: 12))
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel(title)
            .help("录制快捷键，Escape 取消")

            if shortcut != nil && !recording {
                Button { clearHovered = false; changed(nil) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 18, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(clearHovered ? Color.primary : Color.secondary)
                .onHover { clearHovered = $0 }
                .accessibilityLabel("清除快捷键")
                .help("清除快捷键")
            }
        }
        .padding(.horizontal, 7)
        .background(.primary.opacity(hovering || recording ? 0.13 : 0.08), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0; if !$0 { clearHovered = false } }
        .popover(isPresented: $recording, arrowEdge: .bottom) {
            recordingPanel
        }
        .onChange(of: recording) { _, active in if !active { finish() } }
        .onDisappear { finish() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in finish() }
    }
    @ViewBuilder private var recorderLabel: some View {
        if let shortcut { Keycaps(keys: shortcut.keycaps) }
        else { Text(compact ? "添加快捷键" : "录制快捷键") }
    }

    private var recordingPanel: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                Text(draft == nil ? "按下要设置的快捷键" : "按 ⌫ 删除，或输入新的快捷键")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                if !liveModifiers.isEmpty && draft == nil {
                    Keycaps(keys: liveModifiers).padding(10)
                        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
                if let draft {
                    Keycaps(keys: liveModifiers.isEmpty ? draft.keycaps : liveModifiers).padding(10)
                        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .help("直接按键可重新录制；下方可调整修饰键")
                    HStack(spacing: 8) {
                        ForEach([UInt32(4096), 2048, 512, 256], id: \.self) { mask in
                            Button {
                                self.draft?.modifiers ^= mask
                            } label: {
                                Text(mask == 4096 ? "⌃" : mask == 2048 ? "⌥" : mask == 512 ? "⇧" : "⌘")
                                    .foregroundStyle(draft.modifiers & mask != 0 ? Color.primary : Color.secondary)
                            }.buttonStyle(ContentActionButtonStyle())
                        }
                    }
                } else if liveModifiers.isEmpty {
                    Text("等待输入…").font(.title3).foregroundStyle(.tertiary).frame(height: 48)
                }
                Text("点击修饰键可继续调整").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(28)
            Divider()
            HStack {
                icon.frame(width: 20, height: 20).accessibilityHidden(true)
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer()
                Button("取消") { finish() }.buttonStyle(.plain)
                Keycap(text: "Esc")
                Button("完成") { changed(draft); finish() }.buttonStyle(.plain)
                Keycap(text: "↩")
            }.padding(16)
        }
        .frame(width: 350)
    }

    private func start() {
        guard !recording else { return }
        draft = shortcut
        liveModifiers = []; keyHeld = false
        (NSApp.delegate as? Delegate)?.shortcuts.suspend(); recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.type == .flagsChanged {
                if !keyHeld {
                    liveModifiers = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
                        .compactMap { modifiers.contains($0.0) ? $0.1 : nil }
                }
                return event
            }
            if event.type == .keyUp { keyHeld = false; return event }
            keyHeld = true
            liveModifiers = []
            if modifiers.isEmpty {
                if event.keyCode == 53 { finish(); return nil }
                if event.keyCode == 36 { changed(draft); finish(); return nil }
                if event.keyCode == 51 || event.keyCode == 117 { draft = nil; return nil }
            }
            draft = Shortcut(event: event)
            return nil
        }
    }
    private func finish() {
        liveModifiers = []; keyHeld = false
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if recording { recording = false; do { try (NSApp.delegate as? Delegate)?.shortcuts.resume() } catch { (NSApp.delegate as? Delegate)?.model.error = error.localizedDescription } }
    }
}
