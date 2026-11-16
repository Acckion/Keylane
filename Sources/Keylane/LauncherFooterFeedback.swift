import AppKit
import Combine
import SwiftUI

struct LauncherFooterFeedback: Equatable {
    let message: String
    let style: ToastStyle
    var actionTitle: String? = nil
    var label: String { actionTitle.map { message + " · " + $0 } ?? message }
}

final class LauncherFooterFeedbackPresenter {
    @Published private(set) var current: LauncherFooterFeedback?
    private var dismissal: DispatchWorkItem?
    private var action: (() -> Void)?

    func show(_ message: String, style: ToastStyle, in window: NSWindow,
              actionTitle: String? = nil, action: (() -> Void)? = nil) {
        dismissal?.cancel()
        self.action = action
        let feedback = LauncherFooterFeedback(message: message, style: style, actionTitle: actionTitle)
        current = feedback
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: feedback.label])
        let dismissal = DispatchWorkItem { [weak self] in self?.clear() }
        self.dismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + (action == nil ? 3 : 8), execute: dismissal)
    }

    func performAction() {
        let action = action
        clear()
        action?()
    }

    func clear() {
        dismissal?.cancel()
        dismissal = nil
        action = nil
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
            Text(feedback.label)
                .font(.system(size: Self.fontSize, weight: .medium))
                .lineLimit(1)
        }
        .padding(.leading, Self.leadingInset)
        .padding(.trailing, Self.trailingInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension UtilityActions {
    static func copy(_ value: String, feedback: String) {
        let copied = copy(value)
        (NSApp.delegate as? Delegate)?.showLauncherFeedback(copied ? feedback : "无法复制到剪贴板",
                                                            style: copied ? .success : .failure)
    }
}
