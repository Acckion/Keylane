import AppKit
import ApplicationServices
import Foundation
import KeylaneCore
@preconcurrency import ScreenCaptureKit

enum AIWindowVisualCapture {
    struct Window: Identifiable, @unchecked Sendable {
        let window: SCWindow
        let application: String
        var id: UInt32 { window.windowID }
        var title: String { String((window.title ?? "未命名窗口").prefix(200)) }
    }
    struct Snapshot: @unchecked Sendable {
        let target: Window
        let image: CGImage
        let blocks: [AIWindowAccessibility.Block]
        let capturedAt: Date
        func globalRegion(_ normalized: CGRect) -> CGRect {
            AIVisualRegion.globalRect(normalized, window: target.window.frame)
        }
        func cropped(_ region: CGRect) throws -> CGImage {
            let rect = try AIVisualRegion.pixelRect(region, width: image.width, height: image.height)
            guard let result = image.cropping(to: rect) else { throw AIResponseError.invalidImage }
            return result
        }
    }
    static func windows() async throws -> [Window] {
        guard CGPreflightScreenCaptureAccess() else { throw AIResponseError.visualSourceRevoked }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        return content.windows.compactMap { window in
            guard let app = window.owningApplication, app.processID != ProcessInfo.processInfo.processIdentifier,
                  window.windowLayer == 0, window.isOnScreen, window.frame.width >= 40, window.frame.height >= 40 else { return nil }
            return .init(window: window, application: String(app.applicationName.prefix(120)))
        }.sorted { ($0.application, $0.title) < ($1.application, $1.title) }
    }
    static func capture(_ selected: Window, accessibility: Bool) async throws -> Snapshot {
        let current = try await windows()
        guard let target = current.first(where: { $0.id == selected.id }),
              target.window.owningApplication?.processID == selected.window.owningApplication?.processID,
              target.window.frame == selected.window.frame, target.title == selected.title else { throw Failure("窗口已变化，请刷新后重新选择。") }
        let frame = target.window.frame
        let scale = min(1, 2048 / max(frame.width, frame.height))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(frame.width * scale)); configuration.height = max(1, Int(frame.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.includeChildWindows = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target.window), configuration: configuration)
        try Task.checkCancellation()
        let capturedAt = Date()
        var blocks: [AIWindowAccessibility.Block] = []
        if accessibility, AXIsProcessTrusted(), let pid = target.window.owningApplication?.processID {
            let task = Task.detached(priority: .userInitiated) {
                let matches = try AIWindowAccessibility.windows(pid: pid).filter {
                    abs($0.frame.minX - frame.minX) < 2 && abs($0.frame.minY - frame.minY) < 2 &&
                    abs($0.frame.width - frame.width) < 2 && abs($0.frame.height - frame.height) < 2 && $0.title == target.title
                }
                guard matches.count == 1, let window = matches.first else { return [AIWindowAccessibility.Block]() }
                return try AIWindowAccessibility.read(window)
            }
            blocks = (try? await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }) ?? []
        }
        try Task.checkCancellation()
        guard CGPreflightScreenCaptureAccess() else { throw AIResponseError.visualSourceRevoked }
        return .init(target: target, image: image, blocks: blocks, capturedAt: capturedAt)
    }
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
