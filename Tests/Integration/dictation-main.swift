import Foundation
import KeylaneCore
import AVFoundation

// The production credential reader is deliberately absent from this executable.
enum DictationCredentials { static func read(_ options: DictationOptions) throws -> String? { nil } }

final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock(); Self.requests += 1; let handler = Self.handler; Self.lock.unlock()
            let (status, body) = try handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

func encodeSyntheticAudio(in directory: URL) async throws -> URL {
    let url = directory.appendingPathComponent("encoded-fixture.m4a")
    let encoder = try DictationAudioEncoder(url: url)
    var format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
        mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var description: CMAudioFormatDescription?
    require(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format, layoutSize: 0,
        layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr, "synthetic audio format")
    for chunk in 0..<20 {
        let samples = (0..<2400).flatMap { frame -> [Float] in
            let value = Float(sin(Double(chunk * 2400 + frame) / 48000 * 440 * 2 * .pi) * 0.1)
            return [value, value]
        }
        let bytes = samples.withUnsafeBytes { Data($0) }
        var block: CMBlockBuffer?
        require(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
            flags: 0, blockBufferOut: &block) == noErr, "synthetic audio buffer")
        require(CMBlockBufferAssureBlockMemory(block!) == noErr, "synthetic audio allocation")
        let status = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes.count) }
        require(status == noErr, "synthetic audio bytes")
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: CMTime(value: Int64(chunk * 2400), timescale: 48000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        require(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description,
            sampleCount: 2400, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, "synthetic capture sample")
        let deadline = Date().addingTimeInterval(3)
        while encoder.hasSamples && !encoder.ready && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        do { try encoder.append(sample!) }
        catch { print("Synthetic encoder chunk \(chunk): \(encoder.diagnostic)"); throw error }
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        encoder.finish { continuation.resume(with: $0) }
    }
    let file = try AVAudioFile(forReading: url)
    require(file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1, "AAC resampled to 16 kHz mono")
    require(file.length >= 15000 && file.length <= 20000, "one second of audio survives encoding")
    print("Dictation AAC encoding passed: synthetic 48 kHz stereo → 16 kHz mono, no microphone or playback.")
    return url
}

func run() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = try await encodeSyntheticAudio(in: directory)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FixtureProtocol.self]
    let client = DictationCloudClient(configuration: config, readKey: { _ in "fixture-key" })
    var options = DictationOptions()

    FixtureProtocol.handler = { request in
        require(request.url?.path == "/v1/audio/transcriptions", "OpenAI audio route")
        require(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key", "OpenAI auth")
        return (200, Data("{\"text\":\"你好，Keylane。\"}".utf8))
    }
    let text = try await client.transcribe(audio: audio, options: options)
    require(text == "你好，Keylane。", "Unicode response survives transport")

    options.provider = .elevenLabs; options.endpoint = options.provider.endpoint; options.model = options.provider.model
    FixtureProtocol.handler = { request in
        require(request.url?.path == "/v1/speech-to-text", "ElevenLabs route")
        require(request.value(forHTTPHeaderField: "xi-api-key") == "fixture-key", "ElevenLabs auth")
        require(request.value(forHTTPHeaderField: "Authorization") == nil, "no mixed auth headers")
        return (200, Data("{\"text\":\"Scribe fixture\"}".utf8))
    }
    let scribe = try await client.transcribe(audio: audio, options: options)
    require(scribe == "Scribe fixture", "ElevenLabs JSON response")

    for status in [401, 403, 429, 500] {
        FixtureProtocol.handler = { _ in (status, Data("provider echoes fixture-key".utf8)) }
        do { _ = try await client.transcribe(audio: audio, options: options); require(false, "HTTP \(status) must fail") }
        catch let error as DictationError {
            require(error == .http(status), "typed provider status")
            require(!error.localizedDescription.contains("fixture-key"), "provider body never exposed")
        }
    }
    for (data, expected) in [(Data("{\"text\":\" \"}".utf8), DictationError.emptyTranscript),
                              (Data("not-json".utf8), DictationError.invalidResponse)] {
        FixtureProtocol.handler = { _ in (200, data) }
        do { _ = try await client.transcribe(audio: audio, options: options); require(false, "invalid response") }
        catch let error as DictationError { require(error == expected, "typed invalid response") }
    }
    for body in ["{}", "not json", "{\"text\":\"   \"}"] {
        FixtureProtocol.handler = { _ in (200, Data(body.utf8)) }
        do { _ = try await client.transcribe(audio: audio, options: options); require(false, "bad response must fail") }
        catch is DictationError { }
    }
    FixtureProtocol.handler = { _ in (200, Data(repeating: 32, count: DictationCloudRequest.maximumResponseBytes + 1)) }
    do { _ = try await client.transcribe(audio: audio, options: options); require(false, "response bound") }
    catch let error as DictationError { require(error == .responseTooLarge, "bounded response read") }

    let before = FixtureProtocol.requests
    let missingKey = DictationCloudClient(configuration: config, readKey: { _ in nil })
    do { _ = try await missingKey.transcribe(audio: audio, options: options); require(false, "missing credential") }
    catch let error as DictationError { require(error == .missingKey, "typed missing credential") }
    require(FixtureProtocol.requests == before, "missing key cannot send audio")
    let cancelled = Task { try await client.transcribe(audio: audio, options: options) }
    cancelled.cancel()
    do { _ = try await cancelled.value; require(false, "cancelled request") }
    catch is CancellationError {}
    require(FixtureProtocol.requests == before, "cancelled request cannot send audio")
    print("Dictation transport fixtures passed; no microphone, real credentials, clipboard, or external network used.")
}

Task {
    do { try await run(); exit(0) }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
dispatchMain()
