import AVFoundation
import KeylaneCore

/// The same AAC encoder accepts capture samples and deterministic synthetic samples in tests.
final class DictationAudioEncoder {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private(set) var hasSamples = false
    var ready: Bool { input.isReadyForMoreMediaData }
    var diagnostic: String { "state=\(writer.status.rawValue), ready=\(input.isReadyForMoreMediaData), code=\((writer.error as NSError?)?.code ?? 0)" }

    init(url: URL) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw AITranscriptionError.invalidAudio }
        writer.add(input)
    }
    func append(_ sample: CMSampleBuffer) throws {
        guard CMSampleBufferDataIsReady(sample) else { throw AITranscriptionError.invalidAudio }
        if !hasSamples {
            guard writer.startWriting() else { throw AITranscriptionError.invalidAudio }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData, input.append(sample) else { throw AITranscriptionError.invalidAudio }
        hasSamples = true
    }
    func finish(_ completion: @escaping (Result<Void, Error>) -> Void) {
        guard hasSamples, writer.status == .writing else { completion(.failure(AITranscriptionError.invalidAudio)); return }
        input.markAsFinished()
        writer.finishWriting { [writer] in
            completion(writer.status == .completed ? .success(()) : .failure(AITranscriptionError.invalidAudio))
        }
    }
    func cancel() { if writer.status == .writing { writer.cancelWriting() } }
}
