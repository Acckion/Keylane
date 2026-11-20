import AVFoundation
import Foundation
import KeylaneCore

/// Capture and encoding share one serial queue. No capture is created before the user starts.
final class DictationCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "org.keylane.dictation.capture", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var encoder: DictationAudioEncoder?
    private var firstSample = false
    private var cancelled = false
    private var lastMeter = 0.0
    private var started: (() -> Void)?
    private var meter: ((Double) -> Void)?
    private var failure: ((Error) -> Void)?
    private var runtimeError: NSObjectProtocol?

    static var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    func start(url: URL, preferredDevices: [String], started: @escaping () -> Void,
               meter: @escaping (Double) -> Void, failure: @escaping (Error) -> Void) {
        queue.async { [self] in
            guard !cancelled else { return }
            do {
                guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw DictationError.invalidAudio }
                let devices = Self.microphones
                let chosen = preferredDevices.lazy.compactMap { id in devices.first { $0.uniqueID == id } }.first
                    ?? AVCaptureDevice.default(for: .audio)
                guard let device = chosen else { throw DictationError.invalidAudio }
                let session = AVCaptureSession()
                let deviceInput = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureAudioDataOutput()
                guard session.canAddInput(deviceInput), session.canAddOutput(output) else { throw DictationError.invalidAudio }
                session.addInput(deviceInput)
                session.addOutput(output)
                output.setSampleBufferDelegate(self, queue: queue)
                let encoder = try DictationAudioEncoder(url: url)
                self.session = session; self.output = output; self.encoder = encoder
                self.started = started; self.meter = meter; self.failure = failure
                runtimeError = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
                    guard let self else { return }
                    self.queue.async { if self.session != nil && !self.cancelled { self.reportFailure() } }
                }
                session.startRunning()
                guard session.isRunning else { throw DictationError.invalidAudio }
            } catch { release(); DispatchQueue.main.async { failure(error) } }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !cancelled, let encoder, CMSampleBufferDataIsReady(sample) else { return }
        do { try encoder.append(sample) } catch { reportFailure(); return }
        if !firstSample {
            firstSample = true
            let callback = started; started = nil
            DispatchQueue.main.async { callback?() }
        }
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        if time - lastMeter >= 0.05 {
            lastMeter = time
            let levels = connection.audioChannels.map { Double($0.averagePowerLevel) }
            let value = pow(10, (levels.max() ?? -80) / 20)
            let callback = meter
            DispatchQueue.main.async { callback?(min(1, value * 5)) }
        }
    }

    func finish(_ completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            output?.setSampleBufferDelegate(nil, queue: nil)
            session?.stopRunning()
            session = nil; output = nil
            guard !cancelled, firstSample, let encoder else {
                release(); DispatchQueue.main.async { completion(.failure(DictationError.invalidAudio)) }; return
            }
            encoder.finish { [self] result in
                queue.async {
                    self.release()
                    DispatchQueue.main.async { completion(result) }
                }
            }
        }
    }
    func cancel() { queue.async { [self] in cancelled = true; release() } }
    private func reportFailure() {
        let callback = failure
        cancelled = true; release()
        DispatchQueue.main.async { callback?(DictationError.invalidAudio) }
    }
    private func release() {
        if let runtimeError { NotificationCenter.default.removeObserver(runtimeError) }; runtimeError = nil
        output?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning()
        encoder?.cancel()
        session = nil; output = nil; encoder = nil
        started = nil; meter = nil; failure = nil
    }
}
