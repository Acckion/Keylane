import AppKit
import ApplicationServices
import SwiftUI
import KeylaneCore

struct AIVisualPickerMode {
    var textOnly = false
    var applicationPID: pid_t?
    var applicationName = "上一个应用"
}

/// Both conversation surfaces use this explicit preview and draft-bound host sheet.
@MainActor struct AIVisualContextSheet: View {
    let mode: AIVisualPickerMode
    let add: (AIConversationAttachment) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var windows: [AIWindowVisualCapture.Window] = []
    @State private var axWindows: [AIWindowAccessibility.Window] = []
    @State private var selected: UInt32?
    @State private var selectedAX: Int?
    @State private var snapshot: AIWindowVisualCapture.Snapshot?
    @State private var textPreview: AIConversationAttachment?
    @State private var region = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var includeAX = true
    @State private var busy = false
    @State private var message = ""
    @State private var operation: Task<Void, Never>?
    @State private var generation = UUID()
    private var hasPreview: Bool { snapshot != nil || textPreview != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode.textOnly ? "读取窗口文字" : "窗口与区域视觉上下文").font(.title2.bold())
            Text(mode.textOnly ? "仅通过辅助功能读取所选窗口的可访问文字，不截屏。" : "选择窗口后预览；可在图像上拖动框选区域。图像与该范围内的文字只加入草稿，不自动发送。")
                .font(.callout).foregroundStyle(.secondary)
            if mode.textOnly { Text(mode.applicationName).font(.caption).foregroundStyle(.secondary) }
            if !hasPreview {
                windowList.disabled(busy)
                if !mode.textOnly {
                    Toggle("补充辅助功能文字", isOn: $includeAX).disabled(busy)
                    if includeAX && !AXIsProcessTrusted() { accessibilityButton.disabled(busy) }
                }
            } else if let snapshot {
                Text(snapshot.target.application + " · " + snapshot.target.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                AIVisualRegionPreview(image: snapshot.image, region: $region).allowsHitTesting(!busy)
                Text(region == CGRect(x: 0, y: 0, width: 1, height: 1) ? "范围：整个所选窗口" : "范围：框选区域；区域外的辅助功能文字不会加入")
                    .font(.caption).foregroundStyle(.secondary)
                if snapshot.blocks.isEmpty { Text("未取得辅助功能文字；仍会加入图像并尝试 OCR。可返回后授予辅助功能权限。").font(.caption).foregroundStyle(.secondary) }
                Button("恢复整个窗口") { region = CGRect(x: 0, y: 0, width: 1, height: 1) }.buttonStyle(ContentActionButtonStyle())
            } else if let textPreview {
                ScrollView { Text(textPreview.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                    .frame(height: 300).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                if hasPreview {
                    Button("重新选择") { resetPreview() }.disabled(busy)
                    Button("加入草稿") { finish() }.buttonStyle(.borderedProminent).disabled(busy).keyboardShortcut(.defaultAction)
                } else {
                    Button("读取并预览") { prepare() }.buttonStyle(.borderedProminent)
                        .disabled(busy || (mode.textOnly ? selectedAX == nil : selected == nil)).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(22).frame(width: 610, height: 590)
            .task { load() }
            .onDisappear { generation = UUID(); operation?.cancel() }
    }
    private var accessibilityButton: some View {
        Button("允许辅助功能访问") {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            message = "请在系统设置中授权，然后点击刷新。"
        }.buttonStyle(ContentActionButtonStyle())
    }
    @ViewBuilder private var windowList: some View {
        if mode.textOnly {
            if !AXIsProcessTrusted() { accessibilityButton }
            List(selection: $selectedAX) {
                ForEach(axWindows.indices, id: \.self) { index in Text(axWindows[index].title).tag(index) }
            }.frame(height: 300)
        } else if !CGPreflightScreenCaptureAccess() {
            VStack(alignment: .leading, spacing: 14) {
                Text("窗口图像需要屏幕录制权限；也可以取消后选择只读取辅助功能文字。")
                Button("允许屏幕录制") { _ = CGRequestScreenCaptureAccess(); message = "授权后请点击刷新；系统可能要求重启应用。" }
                    .buttonStyle(ContentActionButtonStyle())
            }.frame(height: 270)
        } else {
            List(selection: $selected) {
                ForEach(windows) { window in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(window.title).lineLimit(1)
                        Text(window.application).font(.caption).foregroundStyle(.secondary)
                    }.tag(window.id)
                }
            }.frame(height: 270)
        }
        Button("刷新窗口") { load() }.buttonStyle(ContentActionButtonStyle()).disabled(busy)
    }
    private func load() {
        generation = UUID(); let token = generation
        operation?.cancel(); busy = true; message = ""; selected = nil; selectedAX = nil
        operation = Task { @MainActor in
            defer { if generation == token { busy = false } }
            do {
                if mode.textOnly {
                    guard let pid = mode.applicationPID else { throw AIWindowVisualCapture.Failure("没有可读取的上一个应用。请先切换到目标应用，再返回此处。") }
                    let task = Task.detached { try AIWindowAccessibility.windows(pid: pid) }
                    let values = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                    guard !Task.isCancelled, generation == token else { return }; axWindows = values
                } else {
                    let values = try await AIWindowVisualCapture.windows()
                    guard !Task.isCancelled, generation == token else { return }; windows = values
                }
            } catch { if !Task.isCancelled, generation == token { message = error.localizedDescription } }
        }
    }
    private func resetPreview() {
        operation?.cancel(); generation = UUID(); busy = false; snapshot = nil; textPreview = nil
        region = CGRect(x: 0, y: 0, width: 1, height: 1); load()
    }
    private func prepare() {
        let token = generation; busy = true; message = ""
        operation = Task { @MainActor in
            defer { if generation == token { busy = false } }
            do {
                if mode.textOnly {
                    guard let index = selectedAX, axWindows.indices.contains(index) else { return }
                    let window = axWindows[index]
                    let task = Task.detached { try AIWindowAccessibility.read(window) }
                    let blocks = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                    guard !blocks.isEmpty else { throw AIWindowVisualCapture.Failure("应用未提供可读取的文字。可取消后改用窗口图像。") }
                    guard !Task.isCancelled, generation == token else { return }
                    let source = AIVisualSource(application: mode.applicationName, windowTitle: window.title, windowID: 0, capturedAt: Date(), usedAccessibility: true, requiresScreenCapture: false)
                    textPreview = .init(title: window.title + "（辅助功能文字）", text: AIVisualText.merge(accessibility: blocks.map(\.contextText), ocr: ""), symbol: "accessibility", visualSource: source)
                } else {
                    guard let target = windows.first(where: { $0.id == selected }) else { return }
                    let value = try await AIWindowVisualCapture.capture(target, accessibility: includeAX)
                    guard !Task.isCancelled, generation == token else { return }; snapshot = value
                }
            } catch { if !Task.isCancelled, generation == token { message = error.localizedDescription } }
        }
    }
    private func finish() {
        if let textPreview, let source = textPreview.visualSource {
            do { try AIVisualInputPolicy.validateSources([source]); add(textPreview); dismiss() }
            catch { message = error.localizedDescription }
            return
        }
        guard let snapshot else { return }
        let token = generation, crop = region
        busy = true; message = ""
        operation = Task { @MainActor in
            defer { if generation == token { busy = false } }
            do {
                let image = try snapshot.cropped(crop)
                let allowed = snapshot.globalRegion(crop)
                let blocks = snapshot.blocks.filter { allowed.contains($0.frame) }.map(\.contextText)
                let source = AIVisualSource(application: snapshot.target.application, windowTitle: snapshot.target.title,
                    windowID: snapshot.target.id, capturedAt: snapshot.capturedAt, usedAccessibility: !blocks.isEmpty)
                let value = try await AIVisualImageLoader.attachment(image: image, title: snapshot.target.title + (crop.width < 1 || crop.height < 1 ? "（区域）" : "（窗口）"), accessibility: blocks, source: source)
                guard !Task.isCancelled, generation == token else { return }; add(value); dismiss()
            } catch { if !Task.isCancelled, generation == token { message = error.localizedDescription } }
        }
    }
}
