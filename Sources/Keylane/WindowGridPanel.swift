import AppKit
import KeylaneCore
import SwiftUI

final class WindowGridPanel {
    private let panel: NSPanel
    private var completion: ((CGRect?) -> Void)?
    private var activationObserver: NSObjectProtocol?
    private var keyMonitor: Any?

    init(display: CGRect, options: WindowPlacementOptions, completion: @escaping (CGRect?) -> Void) {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = CGRect(x: display.minX, y: top - display.maxY, width: display.width, height: display.height)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.completion = completion
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: WindowGridView(options: options) { [weak self] selection in
            self?.finish(selection)
        })
    }

    func show() {
        panel.orderFrontRegardless()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                               object: nil, queue: .main) { [weak self] _ in
            self?.finish(nil)
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.finish(nil) }
        }
    }

    func dismiss() { finish(nil) }

    private func finish(_ selection: CGRect?) {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        activationObserver = nil
        keyMonitor = nil
        panel.orderOut(nil)
        let callback = completion
        completion = nil
        callback?(selection)
    }
}

private struct WindowGridView: View {
    let options: WindowPlacementOptions
    let select: (CGRect?) -> Void
    @State private var selection: CGRect?
    private let columns = 6
    private let rows = 4

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Color.black.opacity(0.28)
                Canvas { context, size in
                    let grid = Path { path in
                        for i in 1..<columns {
                            let x = size.width * CGFloat(i) / CGFloat(columns)
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: size.height))
                        }
                        for i in 1..<rows {
                            let y = size.height * CGFloat(i) / CGFloat(rows)
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: size.width, y: y))
                        }
                    }
                    context.stroke(grid, with: .color(.white.opacity(0.64)), lineWidth: 1)
                    if let selection,
                       let preview = WindowPlacement.region(selection).frame(for: CGRect(origin: .zero, size: size),
                           displays: [CGRect(origin: .zero, size: size)], windowGap: options.windowGap, screenGap: options.screenGap) {
                        let shape = Path(roundedRect: preview, cornerRadius: 8)
                        context.fill(shape, with: .color(.accentColor.opacity(0.40)))
                        context.stroke(shape, with: .color(.white), lineWidth: 2)
                    }
                }
                .accessibilityHidden(true)

                VStack {
                    HStack {
                        Text("拖动选择窗口区域").padding(10).background(.regularMaterial, in: Capsule())
                        Spacer()
                        Button("取消", systemImage: "xmark") { select(nil) }
                            .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
                    }
                    Spacer()
                }
                .padding(12)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { selection = region(from: $0.startLocation, to: $0.location, in: size) }
                .onEnded { select(region(from: $0.startLocation, to: $0.location, in: size)) })
        }
    }

    private func region(from start: CGPoint, to end: CGPoint, in size: CGSize) -> CGRect {
        func cell(_ value: CGFloat, length: CGFloat, count: Int) -> Int {
            let fraction = min(0.99999, max(0, value / max(length, 1)))
            return Int(fraction * CGFloat(count))
        }
        let left = cell(min(start.x, end.x), length: size.width, count: columns)
        let right = cell(max(start.x, end.x), length: size.width, count: columns)
        let top = cell(min(start.y, end.y), length: size.height, count: rows)
        let bottom = cell(max(start.y, end.y), length: size.height, count: rows)
        return CGRect(x: CGFloat(left) / CGFloat(columns), y: CGFloat(top) / CGFloat(rows),
                      width: CGFloat(right - left + 1) / CGFloat(columns), height: CGFloat(bottom - top + 1) / CGFloat(rows))
    }
}
