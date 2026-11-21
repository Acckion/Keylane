import ApplicationServices
import Foundation
import KeylaneCore

/// Bounded reads of one explicitly selected window. No application-wide text traversal.
enum AIWindowAccessibility {
    struct Window: @unchecked Sendable {
        let element: AXUIElement
        let pid: pid_t
        let title: String
        let frame: CGRect
    }
    struct Block: Sendable {
        let frame: CGRect
        let text: String
        var role = ""
        var contextText: String {
            let labels = ["AXButton": "按钮", "AXLink": "链接", "AXHeading": "标题", "AXTextField": "输入框",
                          "AXTextArea": "正文", "AXCheckBox": "复选项", "AXRadioButton": "单选项", "AXPopUpButton": "弹出选项"]
            return labels[role].map { $0 + "：" + text } ?? text
        }
    }
    static func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success ? value : nil
    }
    static func frame(_ node: AXUIElement) -> CGRect? {
        guard let p = attribute(node, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(node, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite, point.x.isFinite, point.y.isFinite else { return nil }
        return CGRect(origin: point, size: size)
    }
    static func windows(pid: pid_t) throws -> [Window] {
        guard AXIsProcessTrusted() else { throw AIResponseError.visualSourceRevoked }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        return (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).prefix(40).compactMap { element in
            AXUIElementSetMessagingTimeout(element, 0.08)
            guard let rect = frame(element) else { return nil }
            return .init(element: element, pid: pid, title: String((attribute(element, kAXTitleAttribute) as? String ?? "未命名窗口").prefix(200)), frame: rect)
        }
    }
    static func isCurrent(_ window: Window) -> Bool {
        guard AXIsProcessTrusted(), let current = try? windows(pid: window.pid) else { return false }
        return current.contains { CFEqual($0.element, window.element) && $0.frame == window.frame && $0.title == window.title }
    }
    static func read(_ window: Window) throws -> [Block] {
        guard isCurrent(window) else { throw AIResponseError.visualSourceRevoked }
        let deadline = ContinuousClock.now + .milliseconds(700)
        var queue = [window.element], index = 0, output: [Block] = [], bytes = 0
        while index < queue.count, index < 400, ContinuousClock.now < deadline, bytes < 20_000 {
            try Task.checkCancellation()
            let node = queue[index]; index += 1
            AXUIElementSetMessagingTimeout(node, 0.04)
            let role = attribute(node, kAXRoleAttribute) as? String ?? ""
            let subrole = attribute(node, kAXSubroleAttribute) as? String ?? ""
            guard AIVisualAccessibilityPolicy.canVisit(role: role, subrole: subrole,
                  hidden: attribute(node, "AXHidden") as? Bool == true,
                  protected: attribute(node, "AXProtectedContent") as? Bool == true) else { continue }
            let rect = frame(node)
            if let rect, !window.frame.intersects(rect) { continue }
            if AIVisualAccessibilityPolicy.canReadValue(role: role), let rect, window.frame.contains(rect) {
                var strings: [String] = []
                if let range = attribute(node, kAXVisibleCharacterRangeAttribute), CFGetTypeID(range) == AXValueGetTypeID() {
                    var visible = CFRange()
                    if AXValueGetValue(range as! AXValue, .cfRange, &visible), visible.location >= 0, visible.length > 0 {
                        visible.length = min(visible.length, 4_000)
                        if let parameter = AXValueCreate(.cfRange, &visible) {
                            var value: CFTypeRef?
                            if AXUIElementCopyParameterizedAttributeValue(node, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
                               let text = value as? String { strings.append(text) }
                        }
                    }
                } else if let value = attribute(node, kAXValueAttribute) as? String { strings.append(value) }
                for name in [kAXSelectedTextAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                    if let value = attribute(node, name) as? String { strings.append(value) }
                }
                for value in strings where !value.isEmpty {
                    let text = AIVisualText.bounded(value, bytes: min(4_000, 20_000 - bytes))
                    bytes += text.utf8.count
                    output.append(.init(frame: rect, text: text, role: role))
                }
            }
            let children = (attribute(node, kAXVisibleChildrenAttribute) ?? attribute(node, kAXChildrenAttribute)) as? [AXUIElement] ?? []
            queue.append(contentsOf: children.prefix(max(0, 400 - queue.count)))
        }
        try Task.checkCancellation()
        guard isCurrent(window) else { throw AIResponseError.visualSourceRevoked }
        return output
    }
}
