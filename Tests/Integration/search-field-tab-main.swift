import AppKit
import SwiftUI

private final class TabFixture: ObservableObject {
    @Published var hasTab = false
    @Published var form = false
    @Published var focusToken = 0
    var text = "hello"
    var callbacks: [String] = []
    var generation = "initial-root"
}

private struct FixtureView: View {
    @ObservedObject var state: TabFixture

    var body: some View {
        if state.form {
            Text("Form").frame(width: 400, height: 120)
        } else {
            let generation = state.generation
            SearchField(text: Binding(get: { state.text }, set: { state.text = $0 }),
                        placeholder: "Fixture", focusToken: state.focusToken,
                        submit: {}, move: { _ in }, escape: {},
                        tab: state.hasTab ? { text in
                            precondition(text == "hello")
                            state.callbacks.append(generation)
                            return true
                        } : nil)
                .frame(width: 360, height: 40).padding(20)
        }
    }
}

@main
private enum TabCheck {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let state = TabFixture()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FixtureView(state: state))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        func later(_ delay: Double = 0.4, _ work: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        func tab() {
            precondition(window.isKeyWindow, "Fixture must own keyboard focus")
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: "\t", charactersIgnoringModifiers: "\t",
                                        isARepeat: false, keyCode: 48)!
            app.postEvent(event, atStart: false)
        }

        later {
            app.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            // The search field first mounted on a secondary list without a Tab handler.
            state.hasTab = true
            later {
                tab()
                later {
                    precondition(state.callbacks == ["initial-root"], "Root entry must install a handler on the reused field")
                    state.hasTab = false
                    state.form = true
                    later {
                        state.form = false
                        later {
                            state.generation = "returned-root"
                            state.hasTab = true
                            state.focusToken += 1
                            later {
                                tab()
                                later {
                                    precondition(state.callbacks == ["initial-root", "returned-root"],
                                                 "Returning from form/list must install exactly one current handler")
                                    print("PASS synthetic local Tab: secondary-to-root reuse, form/list/root return and current callback")
                                    app.stop(nil)
                                    app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                                                  modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                  subtype: 0, data1: 0, data2: 0)!, atStart: false)
                                }
                            }
                        }
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { fatalError("Tab fixture timed out") }
        app.run()
        window.close()
    }
}
