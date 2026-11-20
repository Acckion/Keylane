import AppKit
import CoreAudio
import AudioToolbox
import KeylaneCore
import SwiftUI

final class DictationPanel {
    private weak var controller: DictationController?
    private var window: NSPanel?
    init(controller: DictationController) { self.controller = controller }
    func show() {
        guard let controller else { return }
        close()
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 440, height: 116),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: DictationPill(controller: controller))
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame { panel.setFrameOrigin(.init(x: frame.midX - 220, y: frame.minY + 24)) }
        window = panel; panel.orderFrontRegardless()
    }
    func close() { window?.close(); window?.contentView = nil; window = nil }
}

private struct DictationPill: View {
    @ObservedObject var controller: DictationController
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: controller.phase == .failed ? "exclamationmark.circle" : "mic.fill")
                    .foregroundStyle(controller.phase == .failed ? Color.orange : .primary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.statusTitle).font(.system(size: 13, weight: .medium))
                    if controller.phase == .failed {
                        Text(controller.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    } else {
                        HStack(spacing: 3) {
                            ForEach(0..<19, id: \.self) { index in
                                Capsule().fill(.primary.opacity(0.65))
                                    .frame(width: 3, height: controller.phase == .recording
                                        ? max(3, controller.level * (12 + Double((index * 7) % 19))) : 3)
                            }
                            Text(String(format: "%d:%02d", Int(controller.elapsed) / 60, Int(controller.elapsed) % 60))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).padding(.leading, 6)
                        }.frame(height: 28).animation(.easeOut(duration: 0.1), value: controller.level)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if controller.recording {
                    Button("完成听写", systemImage: "stop.fill", action: controller.finish)
                        .labelStyle(.iconOnly).buttonStyle(.bordered)
                } else if controller.busy { ProgressView().controlSize(.small) }
                Button("取消听写", systemImage: "xmark", action: controller.cancel)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            HStack {
                if controller.phase == .failed {
                    Button("听写历史") { controller.cancel(); (NSApp.delegate as? Delegate)?.model.runCommand(.init(rawValue: "dictation-history"), origin: .menu) }
                    Spacer()
                    Button("设置", action: controller.openSettings)
                } else {
                    Menu {
                        Button("自动选择") { controller.forcedStyleID = nil }
                        ForEach(controller.settings.options.styles) { style in
                            Button(style.name) { controller.forcedStyleID = style.id }
                        }
                    } label: {
                        Label(controller.forcedStyleID.flatMap { id in controller.settings.options.styles.first { $0.id == id }?.name } ?? "自动风格", systemImage: "textformat")
                    }.menuStyle(.borderlessButton).fixedSize()
                    Spacer()
                    Text(controller.settings.options.modifiedFinishKeys ? "⌘↩ 完成 · ⌘Esc 取消" : "↩ 完成 · Esc 取消")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.font(.caption)
        }
        .padding(14).frame(width: 440, height: 116)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 23))
    }
}

/// Only touches the selected output while a user-requested recording is active.
final class DictationAudioDucking {
    private var original: (AudioDeviceID, Float32, Float32)?
    private let recoveryKey = "dictation.audioVolumeRecovery"
    func lower() {
        recover()
        guard UserDefaults.standard.dictionary(forKey: recoveryKey) == nil else { return }
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return }
        address = volumeAddress
        var settable: DarwinBoolean = false
        guard AudioHardwareServiceIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return }
        size = UInt32(MemoryLayout<Float32>.size)
        var volume: Float32 = 0
        guard AudioHardwareServiceGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr,
              let uid = deviceUID(device) else { return }
        var lowered = volume * 0.1
        UserDefaults.standard.set(["device": uid, "original": Double(volume), "lowered": Double(lowered)], forKey: recoveryKey)
        if AudioHardwareServiceSetPropertyData(device, &address, 0, nil, size, &lowered) == noErr { original = (device, volume, lowered) }
        else { UserDefaults.standard.removeObject(forKey: recoveryKey) }
    }
    func recover() {
        if original == nil, let saved = UserDefaults.standard.dictionary(forKey: recoveryKey),
           let uid = saved["device"] as? String, let previous = saved["original"] as? Double, let lowered = saved["lowered"] as? Double,
           previous.isFinite, lowered.isFinite, (0...1).contains(previous), (0...1).contains(lowered), let device = device(matching: uid) {
            original = (device, Float32(previous), Float32(lowered))
        }
        restore()
    }
    func restore() {
        guard let (device, previous, lowered) = original else { return }
        original = nil
        var address = volumeAddress
        var current: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioHardwareServiceGetPropertyData(device, &address, 0, nil, &size, &current) == noErr else { return }
        guard abs(current - lowered) < 0.002 else { UserDefaults.standard.removeObject(forKey: recoveryKey); return }
        var restore = previous
        if AudioHardwareServiceSetPropertyData(device, &address, 0, nil, size, &restore) == noErr { UserDefaults.standard.removeObject(forKey: recoveryKey) }
    }
    private func deviceUID(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid as String?
    }
    private func device(matching uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let object = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = devices.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? devices.first { deviceUID($0) == uid } : nil
    }
    private var volumeAddress: AudioObjectPropertyAddress {
        .init(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    deinit { restore() }
}
