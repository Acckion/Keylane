import AppKit
import Combine
import SwiftUI

struct LauncherFooterFeedback: Equatable {
    let message: String
    let style: ToastStyle
}

final class LauncherFooterFeedbackPresenter {
    @Published private(set) var current: LauncherFooterFeedback?
    private var dismissal: DispatchWorkItem?

    func show(_ message: String, style: ToastStyle, in window: NSWindow) {
        dismissal?.cancel()
        current = LauncherFooterFeedback(message: message, style: style)
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: message])
        let dismissal = DispatchWorkItem { [weak self] in self?.clear() }
        self.dismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: dismissal)
    }

    func clear() {
        dismissal?.cancel()
        dismissal = nil
        current = nil
    }
}

struct LauncherFooterFeedbackLabel: View {
    let feedback: LauncherFooterFeedback

    private static let fontSize: CGFloat = 13
    private static let dotSize: CGFloat = 6
    private static let spacing: CGFloat = 12
    private static let trailingInset: CGFloat = 14
    private static var leadingInset: CGFloat { (VisualStyle.launcherControlDiameter - dotSize) / 2 }

    static func width(for message: String) -> CGFloat {
        let textWidth = (message as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium)
        ]).width
        return min(420, ceil(textWidth) + leadingInset + dotSize + spacing + trailingInset)
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            Circle()
                .fill(feedback.style.color)
                .frame(width: Self.dotSize, height: Self.dotSize)
            Text(feedback.message)
                .font(.system(size: Self.fontSize, weight: .medium))
                .lineLimit(1)
        }
        .padding(.leading, Self.leadingInset)
        .padding(.trailing, Self.trailingInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
