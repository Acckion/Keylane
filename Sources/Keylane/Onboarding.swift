import AppKit
import SwiftUI
import KeylaneCore

final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let preferences: UserDefaults
    private let completionKey = "keylane.onboarding.completed"
    private var window: NSWindow?
    private var onClose: (() -> Void)?

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
    }

    var isComplete: Bool { preferences.bool(forKey: completionKey) }
    var isVisible: Bool { window?.isVisible == true }

    func show(model: Model, onClose: @escaping () -> Void) {
        if isVisible {
            bringToFront()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 550),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "欢迎使用 Keylane"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView(model: model) { [weak self] in
            guard let self else { return }
            preferences.set(true, forKey: completionKey)
            self.window?.close()
        })
        window.center()
        self.window = window
        self.onClose = onClose
        bringToFront()
    }

    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        let onClose = self.onClose
        self.onClose = nil
        DispatchQueue.main.async { onClose?() }
    }
}

private struct OnboardingView: View {
    private enum Step: Int {
        case introduction, shortcut, permissions

        var title: String {
            switch self {
            case .introduction: "欢迎使用 Keylane"
            case .shortcut: "设置启动热键"
            case .permissions: "选择要授权的功能"
            }
        }

        var description: String {
            switch self {
            case .introduction: "从一个搜索框打开应用、查找文件和运行命令。剪贴板历史等功能也可以从这里打开。"
            case .shortcut: "按下这个快捷键，就能从任意应用打开 Keylane。之后也可以在设置中修改。"
            case .permissions: "按需授权。你可以直接完成引导，之后在「设置 → 权限」中再开启。"
            }
        }
    }

    let model: Model
    let finish: () -> Void
    @State private var step = Step.introduction
    @State private var shortcutError = ""
    @StateObject private var observation: ViewObservation

    init(model: Model, finish: @escaping () -> Void) {
        self.model = model
        self.finish = finish
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$bindings.map { $0["launcher"] })
        ]))
    }

    var body: some View {
        VStack(spacing: 20) {
            if step != .permissions { Spacer(minLength: 0) }
            VStack(spacing: 10) {
                if step == .introduction, let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                }
                Text(step.title).font(.system(size: 25, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(step.description).font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 28)

            switch step {
            case .introduction:
                Spacer(minLength: 0)
            case .shortcut:
                SettingsGroup {
                    SettingsShortcutBindingRow(title: "Keylane 热键", shortcut: model.bindings["launcher"], symbol: "command") {
                        do {
                            try model.updateShortcut("launcher", value: $0)
                            shortcutError = ""
                        } catch {
                            shortcutError = error.localizedDescription
                        }
                    }
                    if !shortcutError.isEmpty {
                        SettingsDescription(shortcutError)
                    }
                }.padding(.horizontal, 28)
                Spacer(minLength: 0)
            case .permissions:
                ScrollView {
                    PermissionsPreferences(model: model, showsAdditionalPermissions: false)
                        .padding(.horizontal, 28)
                }
                .defaultScrollAnchor(.top)
            }

            HStack {
                if step != .introduction {
                    Button("上一步") { advance(by: -1) }
                }
                Spacer()
                Button(step == .permissions ? "完成" : "继续") { advance(by: 1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
        }
        .padding(.top, 48)
        .padding(.bottom, 24)
        .frame(width: 560, height: 550)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(model.colorScheme)
    }

    private func advance(by offset: Int) {
        if let next = Step(rawValue: step.rawValue + offset) { step = next }
        else if offset > 0 { finish() }
    }
}
