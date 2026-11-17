import AppKit
import AVFoundation
import Combine
import KeylaneCore
import SwiftUI
import UniformTypeIdentifiers

final class CameraPreview: ObservableObject {
    enum State { case idle, starting, running, failed }
    enum PhotoDestination { case clipboard, desktop }

    struct Meeting {
        let returnPage: PageID
        let join: () -> Void
    }

    @Published private(set) var state = State.idle
    @Published var meeting: Meeting?
    @Published private(set) var takingPhoto = false
    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published private(set) var deviceID: String?
    @Published private(set) var mirrored = UserDefaults.standard.object(forKey: "cameraPreview.mirrored") as? Bool ?? true
    @Published private(set) var shutterEnabled = UserDefaults.standard.object(forKey: "cameraPreview.shutterEnabled") as? Bool ?? true

    var canTakePhoto: Bool { state == .running && !takingPhoto }
    var session: AVCaptureSession? { capture?.session }

    private let captureQueue = DispatchQueue(label: "org.keylane.camera-preview", qos: .userInitiated)
    private var captureStart: DispatchWorkItem?
    private var runtimeError: AnyCancellable?
    private var capture: CameraCapture?
    private var discovery: AVCaptureDevice.DiscoverySession?
    private var deviceObservation: NSKeyValueObservation?
    private lazy var shutter = NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Shutter.aif",
                                      byReference: true) ?? NSSound(named: "Tink")

    func start() {
        guard capture == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            state = .failed
            return
        }

        if discovery == nil {
            let finder = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                         mediaType: .video, position: .unspecified)
            discovery = finder
            deviceObservation = finder.observe(\.devices, options: [.new]) { [weak self] finder, change in
                guard let knownDevices = change.newValue else { return }
                DispatchQueue.main.async {
                    guard let self, self.discovery === finder else { return }
                    self.devices = knownDevices
                    if self.state == .failed, !knownDevices.isEmpty { self.start() }
                }
            }
        }
        devices = discovery?.devices ?? []
        let preferredID = UserDefaults.standard.string(forKey: "cameraPreview.deviceID")
        guard let device = devices.first(where: { $0.uniqueID == preferredID })
            ?? AVCaptureDevice.default(for: .video) ?? devices.first else {
            state = .failed
            return
        }
        start(with: device)
    }

    func selectCamera(_ device: AVCaptureDevice) {
        guard device.uniqueID != deviceID || state == .failed,
              devices.contains(where: { $0.uniqueID == device.uniqueID }), !takingPhoto, state != .starting else { return }
        releaseSession()
        start(with: device)
    }

    private func start(with device: AVCaptureDevice) {
        let capture = CameraCapture(queue: captureQueue)
        self.capture = capture
        deviceID = device.uniqueID
        let session = capture.session
        state = .starting
        runtimeError = NotificationCenter.default.publisher(for: AVCaptureSession.runtimeErrorNotification, object: session)
            .receive(on: DispatchQueue.main).sink { [weak self, weak session] _ in
                guard let self, let session, self.session === session else { return }
                self.fail()
            }
        let request = DispatchWorkItem { [weak self, weak session] in
            let started = capture.start(with: device) { [weak self, weak session] in
                DispatchQueue.main.async {
                    guard let self, let session, self.session === session else { return }
                    UserDefaults.standard.set(device.uniqueID, forKey: "cameraPreview.deviceID")
                    self.state = .running
                }
            }
            DispatchQueue.main.async {
                guard let self, let session, self.session === session else { return }
                self.captureStart = nil
                if !started { self.fail() }
            }
            if started {
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak session] in
                    guard let self, let session, self.session === session, self.state == .starting else { return }
                    self.fail()
                }
            }
        }
        captureStart = request
        captureQueue.async(execute: request)
    }

    func stop(completion: (() -> Void)? = nil) {
        releaseSession()
        deviceObservation = nil
        discovery = nil
        devices = []
        deviceID = nil
        state = .idle
        meeting = nil
        if let completion {
            captureQueue.async { DispatchQueue.main.async(execute: completion) }
        }
    }

    private func fail() {
        releaseSession()
        state = .failed
    }

    private func releaseSession() {
        captureStart?.cancel()
        captureStart = nil
        runtimeError = nil
        takingPhoto = false
        guard let capture else { return }
        self.capture = nil
        captureQueue.async { capture.stop() }
    }

    func toggleMirroring() {
        mirrored.toggle()
        UserDefaults.standard.set(mirrored, forKey: "cameraPreview.mirrored")
    }

    func toggleShutter() {
        shutterEnabled.toggle()
        UserDefaults.standard.set(shutterEnabled, forKey: "cameraPreview.shutterEnabled")
    }

    func takePhoto(_ destination: PhotoDestination, aspect: CGFloat) {
        guard canTakePhoto, let capture else { return }
        takingPhoto = true
        capture.takePhoto(mirrored: mirrored, aspect: aspect) { [weak self, weak capture] image in
            DispatchQueue.main.async {
                guard let self, let capture, self.capture === capture else { return }
                guard let image else { self.finishPhoto("未能拍摄照片。", succeeded: false); return }
                if self.shutterEnabled { self.shutter?.play() }
                switch destination {
                case .clipboard:
                    let item = NSPasteboardItem()
                    item.setData(image, forType: .init(UTType.jpeg.identifier))
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    let copied = pasteboard.writeObjects([item])
                    self.finishPhoto(copied ? "已拷贝到剪贴板" : "无法拷贝照片。", succeeded: copied)
                case .desktop:
                    self.saveToDesktop(image, capture: capture)
                }
            }
        }
    }

    private func saveToDesktop(_ image: Data, capture: CameraCapture) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                let desktop = try FileManager.default.url(for: .desktopDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                let timestamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
                    .replacingOccurrences(of: ":", with: "-")
                let file = desktop.appendingPathComponent("Keylane 相机 \(timestamp).jpg")
                try image.write(to: file, options: .withoutOverwriting)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if self.capture === capture { self.takingPhoto = false }
                switch result {
                case .success: self.photoFeedback("照片已保存到桌面", succeeded: true)
                case .failure(let error): self.photoFeedback("无法保存到桌面。\(error.localizedDescription)", succeeded: false)
                }
            }
        }
    }

    private func finishPhoto(_ message: String, succeeded: Bool) {
        takingPhoto = false
        photoFeedback(message, succeeded: succeeded)
    }

    private func photoFeedback(_ message: String, succeeded: Bool) {
        (NSApp.delegate as? Delegate)?.showLauncherFeedback(message, style: succeeded ? .success : .failure)
    }
}

struct CameraPreviewPage: View {
    @ObservedObject var camera: CameraPreview
    let back: () -> Void

    var body: some View {
        ZStack {
            Color.black
            if let session = camera.session {
                let ready = camera.state == .running
                ZStack {
                    CameraVideoView(session: session, ready: ready)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scaleEffect(x: camera.mirrored ? -1 : 1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("实时相机预览")
                        .accessibilityHidden(!ready)
                    CameraAperture(ready: ready)
                }
                .id(ObjectIdentifier(session))
            } else if camera.state == .failed {
                Text("无法打开相机。请确认相机已连接且可用。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                CameraAperture(ready: false)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            Button(action: back) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.22), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .accessibilityLabel("返回")
            .help("返回")
            .padding(VisualStyle.launcherEdgeInset)
        }
    }
}

private struct CameraVideoView: NSViewRepresentable {
    let session: AVCaptureSession
    let ready: Bool

    func makeNSView(context: Context) -> NSView {
        PreviewView(session: session)
    }

    func updateNSView(_ view: NSView, context: Context) {
        if ready, let connection = (view.layer as? AVCaptureVideoPreviewLayer)?.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    private final class PreviewView: NSView {
        let session: AVCaptureSession

        init(session: AVCaptureSession) {
            self.session = session
            super.init(frame: .zero)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { nil }

        override func makeBackingLayer() -> CALayer {
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.backgroundColor = NSColor.black.cgColor
            return preview
        }
    }
}
