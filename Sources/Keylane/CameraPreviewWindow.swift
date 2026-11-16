import AppKit
import AVFoundation

final class CameraPreviewWindow: NSObject, NSWindowDelegate {
    private var session: AVCaptureSession?
    private let captureQueue = DispatchQueue(label: "org.keylane.camera-preview", qos: .userInitiated)
    private var window: NSWindow?
    private var generation = 0
    private var captureStart: DispatchWorkItem?

    func show(activation: WindowActivationBehavior) {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        (NSApp.delegate as? Delegate)?.hideLauncher()
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            activation.apply(to: window)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "相机预览"
        window.minSize = NSSize(width: 320, height: 220)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        activation.apply(to: window)
        self.window = window
        let token = generation
        showMessage("正在打开相机…")
        window.makeKeyAndOrderFront(nil)

        start(token: token)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        generation += 1
        captureStart?.cancel()
        captureStart = nil
        window = nil
        if let session {
            self.session = nil
            captureQueue.async { session.stopRunning() }
        }
    }

    private func start(token: Int) {
        let session = AVCaptureSession()
        self.session = session
        window?.contentView = CameraPreviewView(session: session)
        let request = DispatchWorkItem {}
        captureStart = request
        captureQueue.async { [weak self] in
            guard !request.isCancelled else { return }
            let started = Self.startSession(session)
            DispatchQueue.main.async {
                guard !started, let self, self.generation == token else { return }
                self.showMessage("无法打开相机。请确认相机已连接且可用。")
            }
        }
    }

    private static func startSession(_ session: AVCaptureSession) -> Bool {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        session.startRunning()
        return session.isRunning
    }

    private func showMessage(_ message: String) {
        let content = NSView()
        let label = NSTextField(wrappingLabelWithString: message)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -48)
        ])
        window?.contentView = content
    }
}

private final class CameraPreviewView: NSView {
    private let preview: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        preview.videoGravity = .resizeAspect
        preview.backgroundColor = NSColor.black.cgColor
        layer = preview
        setAccessibilityLabel("实时相机预览")
    }

    required init?(coder: NSCoder) { nil }
}
