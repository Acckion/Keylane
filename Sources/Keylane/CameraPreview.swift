import AppKit
import AVFoundation
import Combine
import KeylaneCore
import SwiftUI

final class CameraPreview: ObservableObject {
    enum State { case idle, starting, running, failed }

    struct Meeting {
        let returnPage: PageID
        let join: () -> Void
    }

    @Published private(set) var state = State.idle
    @Published private(set) var session: AVCaptureSession?
    @Published var meeting: Meeting?

    private let captureQueue = DispatchQueue(label: "org.keylane.camera-preview", qos: .userInitiated)
    private var captureStart: DispatchWorkItem?
    private var runtimeError: AnyCancellable?

    func start() {
        guard session == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            state = .failed
            return
        }

        let session = AVCaptureSession()
        self.session = session
        state = .starting
        runtimeError = NotificationCenter.default.publisher(for: AVCaptureSession.runtimeErrorNotification, object: session)
            .receive(on: DispatchQueue.main).sink { [weak self, weak session] _ in
                guard let self, let session, self.session === session else { return }
                self.fail()
            }
        let request = DispatchWorkItem { [weak self] in
            let started = Self.startSession(session)
            DispatchQueue.main.async {
                guard let self, self.session === session else { return }
                self.captureStart = nil
                if started { self.state = .running }
                else { self.fail() }
            }
        }
        captureStart = request
        captureQueue.async(execute: request)
    }

    func stop(completion: (() -> Void)? = nil) {
        releaseSession()
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
        guard let session else { return }
        self.session = nil
        captureQueue.async { session.stopRunning() }
    }

    private static func startSession(_ session: AVCaptureSession) -> Bool {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        session.startRunning()
        return session.isRunning
    }
}

struct CameraPreviewPage: View {
    @ObservedObject var camera: CameraPreview
    let back: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button(action: back) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("返回")
                .help("返回")
                Spacer()
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.25))
                switch camera.state {
                case .idle:
                    EmptyView()
                case .starting:
                    ProgressView("正在打开相机…")
                case .running:
                    if let session = camera.session {
                        CameraVideoView(session: session).id(ObjectIdentifier(session))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("实时相机预览")
                    }
                case .failed:
                    Text("无法打开相机。请确认相机已连接且可用。")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: 12))
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, VisualStyle.launcherEdgeInset)
        .padding(.top, VisualStyle.launcherEdgeInset)
        .padding(.bottom, VisualStyle.launcherBottomInset)
    }
}

private struct CameraVideoView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        PreviewView(session: session)
    }

    func updateNSView(_ view: NSView, context: Context) {}

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
            preview.videoGravity = .resizeAspect
            preview.backgroundColor = NSColor.black.cgColor
            return preview
        }
    }
}
