import AVFoundation
import CoreImage

/// The session, frame delegate and photo requests share one serial queue.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue: DispatchQueue
    private let output = AVCaptureVideoDataOutput()
    private lazy var imageContext = CIContext()
    private struct PhotoRequest {
        let id = UUID()
        let mirrored: Bool
        let aspect: CGFloat
        let completion: (Data?) -> Void
    }
    private var pendingPhoto: PhotoRequest?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start(with device: AVCaptureDevice) -> Bool {
        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        guard session.canAddOutput(output) else { return false }
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        session.startRunning()
        return session.isRunning
    }

    func stop() {
        pendingPhoto = nil
        output.setSampleBufferDelegate(nil, queue: nil)
        session.stopRunning()
    }

    func takePhoto(mirrored: Bool, aspect: CGFloat, completion: @escaping (Data?) -> Void) {
        let request = PhotoRequest(mirrored: mirrored, aspect: aspect, completion: completion)
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { completion(nil); return }
            self.pendingPhoto = request
            self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.pendingPhoto?.id == request.id else { return }
                self.pendingPhoto = nil
                completion(nil)
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let request = pendingPhoto, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        pendingPhoto = nil
        let image = Self.jpeg(CIImage(cvPixelBuffer: buffer), mirrored: request.mirrored,
                              aspect: request.aspect, context: imageContext)
        request.completion(image)
    }

    static func jpeg(_ input: CIImage, mirrored: Bool, aspect: CGFloat, context: CIContext) -> Data? {
        guard aspect.isFinite, aspect > 0, !input.extent.isEmpty else { return nil }
        let oriented = mirrored ? input.oriented(.upMirrored) : input
        let frame = oriented.extent
        let width = min(frame.width, frame.height * aspect)
        let height = min(frame.height, frame.width / aspect)
        let crop = CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
        let photo = oriented.cropped(to: crop.integral)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        return context.jpegRepresentation(of: photo, colorSpace: colorSpace, options: [:])
    }
}
