import Foundation
import KeylaneCore
import AVFoundation

// Every request injects a synthetic credential reader; no real credentials are accessed.

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
    let encoder: DictationAudioEncoder
    do { encoder = try DictationAudioEncoder(url: url) }
    catch { fputs("Synthetic AAC writer initialization failed: \(error)\n", stderr); throw error }
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
    do {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            encoder.finish { continuation.resume(with: $0) }
        }
    } catch { fputs("Synthetic AAC writer finalize failed: \(encoder.diagnostic)\n", stderr); throw error }
    let file = try AVAudioFile(forReading: url)
    require(file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1, "AAC resampled to 16 kHz mono")
    require(file.length >= 15000 && file.length <= 20000, "one second of audio survives encoding")
    print("Dictation AAC encoding passed: synthetic 48 kHz stereo → 16 kHz mono, no microphone or playback.")
    return url
}

private func verifyDictationReviewRegressions(in directory: URL) async throws {
    let speechDraft = AIConversationComposer()
    speechDraft.offer("已有 😀")
    let speechDraftID = speechDraft.draftID
    require(speechDraft.appendDictation("语音结果", for: speechDraftID), "speech appends to its initiating draft")
    require(speechDraft.text == "已有 😀 语音结果" && speechDraft.selection.location == speechDraft.text.utf16.count,
            "speech preserves draft and advances the UTF-16 selection")
    let attachment = AIConversationAttachment(title: "Generated attachment", text: "Synthetic content", symbol: "doc")
    speechDraft.attachments = [attachment]
    for source in [PageID.root, PageID(rawValue: "fixture-other-page")] {
        let destination = PageID(rawValue: "quick-ai")
        var presentation = LauncherPagePresentation(page: source)
        _ = presentation.update(page: source, visible: true)
        require(presentation.update(page: destination, visible: true).activation == .enter, "opens Quick AI from each source")
        var entrySubmissions = 0
        let requestsBefore = FixtureProtocol.requests
        let seed = LauncherPagePresentation.EntryIntent.existingDraft.resolve(current: "previous page query",
            restored: nil, pageConsumesEntryQuery: true, existingDraft: { speechDraft.text }, enter: { _ in
                entrySubmissions += 1; return ""
            })
        require(entrySubmissions == 0 && FixtureProtocol.requests == requestsBefore, "voice navigation never submits the draft")
        require(seed == speechDraft.text && speechDraft.attachments == [attachment], "voice navigation preserves draft and attachments")

        var manualSubmission: String?
        let explicitlySend = { manualSubmission = AIConversationAttachment.requestText(question: speechDraft.text, attachments: speechDraft.attachments) }
        require(manualSubmission == nil, "draft-only activation leaves manual submission untouched")
        explicitlySend()
        require(manualSubmission?.contains("Synthetic content") == true && manualSubmission?.contains("语音结果") == true,
                "manual submission still includes voice and existing attachments")

        let tab = LauncherPagePresentation.EntryIntent.query("explicit Tab")
        let tabResult = tab.resolve(current: "previous page query", restored: nil, pageConsumesEntryQuery: true,
            existingDraft: { fatalError("Tab is not a draft-only activation") }, enter: { query in
                require(query == "explicit Tab", "explicit Tab still forwards a question"); entrySubmissions += 1; return ""
            })
        require(tabResult == "" && entrySubmissions == 1, "accepted Tab entry continues to submit and clear")
    }
    speechDraft.clear()
    speechDraft.offer("新对话")
    require(!speechDraft.appendDictation("旧结果", for: speechDraftID) && speechDraft.text == "新对话",
            "a stale speech result cannot mutate a new conversation draft")

    var gesture = DictationModifierGesture()
    gesture.arm(holdToTalk: false)
    require(gesture.release() == .toggle, "a standalone modifier release toggles")
    for _ in ["letter chord", "other modifier", "mouse button"] {
        gesture.arm(holdToTalk: false)
        require(!gesture.interrupt() && gesture.release() == .none, "other input disarms toggle without canceling a session")
    }
    gesture.arm(holdToTalk: true)
    require(gesture.release() == .finishHold, "hold release finishes recording")
    gesture.arm(holdToTalk: true)
    require(gesture.interrupt() && gesture.release() == .none, "other input cancels an invoked hold once")

    let history = DictationHistory(directory: directory.appendingPathComponent("retry-history"))
    let failed = DictationRecord(duration: 1, error: "synthetic failure")
    let originalBytes = Data([1, 2, 3])
    let recording = try await history.recordingURL(failed.id)
    try originalBytes.write(to: recording)
    try await history.save(failed, retainRecording: true)
    var retry = DictationSession()
    let token = retry.begin(borrowingRecording: true)
    require(retry.transition(.transcribing, token: token), "retry transcribing")
    if retry.discardsRecordingOnCancel { try await history.discardRecording(failed.id) }
    retry.cancel()
    require(!retry.accepts(token), "canceled retry rejects stale work")
    let preserved = try Data(contentsOf: recording)
    let entries = try await history.list()
    require(preserved == originalBytes && entries.first?.hasRecording == true && entries.first?.error == failed.error,
            "a canceled retry retains the original bytes and index for another retry")
    let fresh = retry.begin()
    require(retry.transition(.transcribing, token: fresh) && retry.discardsRecordingOnCancel, "fresh capture cancellation deletes temporary audio")
    require(retry.transition(.failed, token: fresh) && !retry.discardsRecordingOnCancel, "failed capture retains audio")

    let suite = "KeylaneDictationReview.\(UUID())"
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let configuration = AIConfiguration(preferences: preferences)
    let speech = AIConnection(endpoint: "https://fixture-provider.test/v1/audio/transcriptions", model: "gpt-transcribe")
    require(configuration.save(speech, selectAsDefault: false), "register full transcription endpoint")
    let defaults = configuration.state.defaults
    require(configuration.addProviderModels(["fixture-chat"], from: speech, discoveredUsing: speech) == 1, "import chat from speech connection")
    let chat = configuration.state.connections.first { $0.model == "fixture-chat" }!
    require(chat.taskKind == .text && chat.completionURL?.absoluteString == "https://fixture-provider.test/v1/chat/completions", "imported chat uses API base")
    require(AIConfiguration.credentialQueries(for: chat) as NSArray == AIConfiguration.credentialQueries(for: speech) as NSArray,
            "cross-task import retains credential scope")
    require(configuration.state.defaults == defaults, "cross-task import retains route defaults")
    require(configuration.addProviderModels(["gpt-transcribe-mini"], from: chat, discoveredUsing: chat) == 1, "import speech from chat connection")
    let sibling = configuration.state.connections.first { $0.model == "gpt-transcribe-mini" }!
    require(sibling.transcriptionOptions()?.transcriptionURL?.absoluteString == "https://fixture-provider.test/v1/audio/transcriptions", "imported speech uses correct route")
}

@MainActor
private func verifyOpenRouterDictation(audio: URL) async throws {
    let suite = "KeylaneOpenRouterDictation.\(UUID())"
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let initial = AIConfiguration(preferences: preferences)
    let owner = AIConnection(name: "Saved chat", endpoint: "https://openrouter.ai/api/v1/chat/completions",
                             model: "fixture/chat", providerID: "openrouter")
    require(initial.save(owner, selectAsDefault: true), "save shared OpenRouter connection")
    initial.setEnabled(true)
    require(initial.applyProviderCatalog([.init(id: owner.model)], snapshot: owner, at: Date()), "seed pre-upgrade catalog")
    var legacy = initial.state
    legacy.providerCatalogs?[owner.catalogIdentity] = .init(updatedAt: Date(), modelIDs: [owner.id])
    preferences.set(try JSONEncoder().encode(legacy), forKey: "aiConnections.v1")
    let settings = AIConfiguration(preferences: preferences)
    let defaults = settings.state.defaults
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FixtureProtocol.self]
    let runtime = AIRuntime(configuration: config)
    let catalogRequests = FixtureProtocol.requests
    FixtureProtocol.handler = { request in
        require(request.httpMethod == "GET" && request.url?.path == "/api/v1/models", "shared catalog endpoint")
        require(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key", "catalog reuses provider key")
        if request.url?.query == "output_modalities=transcription" {
            return (200, Data(#"{"data":[{"id":"google/chirp-3","name":"Chirp 3","architecture":{"input_modalities":["audio"],"output_modalities":["transcription"]}},{"id":"openai/whisper-1","architecture":{"input_modalities":["audio"],"output_modalities":["transcription"]}},{"id":"fixture/chat","architecture":{"input_modalities":["text"],"output_modalities":["text"]}},{"id":"fixture/tts","architecture":{"input_modalities":["text"],"output_modalities":["audio"]}}]}"#.utf8))
        }
        require(request.url?.query == nil, "ordinary catalog remains unchanged")
        return (200, Data(#"{"data":[{"id":"fixture/chat"},{"id":"openai/whisper-1"},{"id":"fixture/audio-chat","architecture":{"input_modalities":["audio","text"],"output_modalities":["text"]}}]}"#.utf8))
    }
    let sync = AIProviderCatalogSync(configuration: settings, runtime: runtime, readKey: { _ in "fixture-key" })
    sync.start()
    for _ in 0..<500 {
        if settings.state.providerCatalogs?[owner.catalogIdentity]?.includesTranscriptionModels == true { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    require(settings.state.providerCatalogs?[owner.catalogIdentity]?.includesTranscriptionModels == true,
            "fresh pre-upgrade cache refreshes without waiting six hours")
    require(FixtureProtocol.requests == catalogRequests + 2, "merge both catalogs once")
    let speech = settings.state.connections.first { $0.model == "google/chirp-3" }!
    require(speech.taskKind == .openRouterTranscription && speech.transcriptionOptions()?.provider == .openRouter,
            "unknown speech name classified from output capabilities")
    require(speech.credentialOwnerID == owner.id, "speech shares credential owner")
    require(AIConfiguration.credentialQueries(for: speech) as NSArray == AIConfiguration.credentialQueries(for: owner) as NSArray,
            "speech reuses the same scoped Keychain lookup")
    require(settings.state.connections.filter { $0.model == "openai/whisper-1" }.count == 1, "duplicate model merged")
    require(settings.state.connections.first { $0.model == "openai/whisper-1" }?.taskKind == .openRouterTranscription,
            "duplicate preserves transcription metadata")
    require(!settings.state.connections.contains { $0.model == "fixture/tts" }, "ignore non-STT entries from ignored filters")
    let menu = AIModelMenuCatalog(connections: settings.state.connections, selection: .inherit, query: "", purpose: .transcription)
    require(Set(menu.groups.flatMap(\.models).map(\.model)) == ["google/chirp-3", "openai/whisper-1"],
            "real dictation picker includes speech and excludes audio-chat")
    let chats = AIModelMenuCatalog(connections: settings.state.connections, selection: .inherit, query: "", purpose: .text)
    require(!chats.groups.flatMap(\.models).contains { $0.id == speech.id }, "speech excluded from chat picker")
    require(settings.state.defaults == defaults && settings.state.connection(for: .chat)?.id == owner.id,
            "existing text defaults preserved")
    let restored = AIConfiguration(preferences: preferences)
    require(restored.state.connections.first { $0.id == speech.id }?.transcriptionOptions()?.provider == .openRouter,
            "speech capability survives restart")
    var edited = speech
    edited.modelTask = .text
    require(edited.taskKind == .text && edited.transcriptionOptions() == nil, "explicit capability override wins")
    edited.modelTask = nil; edited.model = "fixture/different-chat"
    require(edited.taskKind == .text, "editing model ID cannot reuse another model's speech metadata")
    require(settings.addProviderModels(["fixture/imported-chat"], from: speech, discoveredUsing: speech) == 1, "import from speech")
    require(settings.state.connections.first { $0.model == "fixture/imported-chat" }?.taskKind == .text,
            "cloned chat does not inherit speech metadata")
    sync.refresh()
    try await Task.sleep(nanoseconds: 100_000_000)
    require(FixtureProtocol.requests == catalogRequests + 2, "upgraded cache prevents repeated discovery")
    let stable = settings.state
    FixtureProtocol.handler = { request in
        if request.url?.query != nil { return (502, Data("private provider error".utf8)) }
        return (200, Data(#"{"data":[{"id":"fixture/new-chat"}]}"#.utf8))
    }
    sync.refresh(force: true)
    for _ in 0..<500 {
        if settings.catalogSyncStatus[owner.catalogIdentity]?.hasPrefix("同步失败") == true { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    require(settings.catalogSyncStatus[owner.catalogIdentity]?.hasPrefix("同步失败") == true, "STT catalog failure surfaced")
    require(settings.state == stable, "failed supplemental catalog cannot remove saved speech or chat models")
    let audioBytes = try Data(contentsOf: audio)
    FixtureProtocol.handler = { request in
        require(request.url?.absoluteString == "https://openrouter.ai/api/v1/audio/transcriptions", "OpenRouter STT route")
        require(request.value(forHTTPHeaderField: "Content-Type") == "application/json", "OpenRouter JSON transport")
        require(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key", "shared OpenRouter credential")
        let data: Data
        if let body = request.httpBody { data = body }
        else {
            let stream = request.httpBodyStream!; stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096); var body = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                require(count >= 0, "read generated upload")
                if count == 0 { break }
                body.append(buffer, count: count)
            }
            data = body
        }
        let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let input = payload["input_audio"] as! [String: String]
        require(payload["model"] as? String == "google/chirp-3" && payload["language"] as? String == "zh", "selected model and language")
        require(input["format"] == "m4a" && Data(base64Encoded: input["data"]!) == audioBytes, "encoder bytes survive JSON transport")
        return (200, Data(#"{"text":"你好，OpenRouter。"}"#.utf8))
    }
    let transcript = try await runtime.transcribe(audio: audio, connection: speech, language: "zh", readKey: { _ in "fixture-key" })
    require(transcript == "你好，OpenRouter。", "OpenRouter transcript reaches shared runtime")
    if ProcessInfo.processInfo.environment["KEYLANE_OPENROUTER_CATALOG"] == "1" {
        let live = try await AIRuntime().listModelCatalog(connection: owner, readKey: { _ in nil })
        let publicSettings = AIConfiguration(preferences: UserDefaults(suiteName: suite + ".public")!)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite + ".public") }
        require(publicSettings.save(owner, selectAsDefault: true), "public catalog setup")
        publicSettings.setEnabled(true)
        require(publicSettings.applyProviderCatalog(live, snapshot: owner, at: Date()), "public catalog merge")
        let liveMenu = AIModelMenuCatalog(connections: publicSettings.state.connections, selection: .inherit, query: "", purpose: .transcription)
        let liveSpeech = liveMenu.groups.flatMap(\.models)
        require(!liveSpeech.isEmpty && liveSpeech.allSatisfy { $0.transcriptionOptions()?.provider == .openRouter }, "live OpenRouter speech catalog reaches picker")
        print("Live public OpenRouter discovery passed: \(liveSpeech.count) dictation choices; no key or recording sent.")
    }
    print("OpenRouter dictation fixtures passed: cache upgrade, shared picker, credentials, defaults, persistence, catalog failures and JSON audio upload.")
}

func run() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await verifyDictationReviewRegressions(in: directory)
    print("Dictation review regressions passed: standalone gestures, borrowed history and cross-task model routes.")
    if ProcessInfo.processInfo.environment["KEYLANE_DICTATION_REVIEW_ONLY"] == "1" { return }
    let audio: URL
    if ProcessInfo.processInfo.environment["KEYLANE_DICTATION_TRANSPORT_ONLY"] == "1" {
        // The injected URLProtocol exercises requests with a payload, not AAC decoding.
        audio = directory.appendingPathComponent("transport-fixture.m4a")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: audio)
    } else {
        audio = try await encodeSyntheticAudio(in: directory)
    }
    try await verifyOpenRouterDictation(audio: audio)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FixtureProtocol.self]
    let client = AIRuntime(configuration: config)
    var connection = AIConnection(endpoint: "https://api.openai.com/v1/chat/completions", model: "gpt-transcribe")

    FixtureProtocol.handler = { request in
        require(request.url?.path == "/v1/audio/transcriptions", "OpenAI audio route")
        require(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key", "OpenAI auth")
        return (200, Data("{\"text\":\"你好，Keylane。\"}".utf8))
    }
    let text = try await client.transcribe(audio: audio, connection: connection, readKey: { _ in "fixture-key" })
    require(text == "你好，Keylane。", "Unicode response survives transport")

    connection = AIConnection(endpoint: "https://api.elevenlabs.io/v1", model: "scribe_v2", providerID: "elevenlabs")
    FixtureProtocol.handler = { request in
        require(request.url?.path == "/v1/speech-to-text", "ElevenLabs route")
        require(request.value(forHTTPHeaderField: "xi-api-key") == "fixture-key", "ElevenLabs auth")
        require(request.value(forHTTPHeaderField: "Authorization") == nil, "no mixed auth headers")
        return (200, Data("{\"text\":\"Scribe fixture\"}".utf8))
    }
    let scribe = try await client.transcribe(audio: audio, connection: connection, readKey: { _ in "fixture-key" })
    require(scribe == "Scribe fixture", "ElevenLabs JSON response")

    FixtureProtocol.handler = { request in
        require(request.url?.path == "/v1/user", "ElevenLabs shared connection test uses authenticated account endpoint")
        require(request.value(forHTTPHeaderField: "xi-api-key") == "fixture-key", "shared account auth")
        return (200, Data("{\"user_id\":\"synthetic-account\"}".utf8))
    }
    try await client.verifyAPIKey(connection: connection, readKey: { _ in "fixture-key" })
    let probe = try await client.testConnection(connection, readKey: { _ in "fixture-key" })
    require(probe.contains("实测"), "connection test does not claim live transcription acceptance")
    FixtureProtocol.handler = { request in
        require(request.url?.path == "/v1/models", "shared model discovery normalizes base URL")
        return (200, Data("[{\"model_id\":\"scribe_v2\"},{\"model_id\":\"eleven_multilingual_v2\"}]".utf8))
    }
    let speechModels = try await client.listModels(connection: connection, readKey: { _ in "fixture-key" })
    require(speechModels == ["scribe_v2"], "text-to-speech models must not be offered as dictation models")

    for status in [401, 403, 429, 500] {
        FixtureProtocol.handler = { _ in (status, Data("provider echoes fixture-key".utf8)) }
        do { _ = try await client.transcribe(audio: audio, connection: connection, readKey: { _ in "fixture-key" }); require(false, "HTTP \(status) must fail") }
        catch let error as AITranscriptionError {
            require(error == .http(status), "typed provider status")
            require(!error.localizedDescription.contains("fixture-key"), "provider body never exposed")
        }
    }
    for (data, expected) in [(Data("{\"text\":\" \"}".utf8), AITranscriptionError.emptyTranscript),
                              (Data("not-json".utf8), AITranscriptionError.invalidResponse)] {
        FixtureProtocol.handler = { _ in (200, data) }
        do { _ = try await client.transcribe(audio: audio, connection: connection, readKey: { _ in "fixture-key" }); require(false, "invalid response") }
        catch let error as AITranscriptionError { require(error == expected, "typed invalid response") }
    }
    for body in ["{}", "not json", "{\"text\":\"   \"}"] {
        FixtureProtocol.handler = { _ in (200, Data(body.utf8)) }
        do { _ = try await client.transcribe(audio: audio, connection: connection, readKey: { _ in "fixture-key" }); require(false, "bad response must fail") }
        catch is AITranscriptionError { }
    }
    FixtureProtocol.handler = { _ in (200, Data(repeating: 32, count: AITranscriptionRequest.maximumResponseBytes + 1)) }
    do { _ = try await client.transcribe(audio: audio, connection: connection, readKey: { _ in "fixture-key" }); require(false, "response bound") }
    catch let error as AITranscriptionError { require(error == .responseTooLarge, "bounded response read") }

    let invalidRequests = FixtureProtocol.requests
    let chat = AIConnection(endpoint: "https://example.test/v1", model: "fixture-chat")
    do {
        _ = try await client.transcribe(audio: audio, connection: chat, readKey: { _ in
            require(false, "chat-only model must not access credentials for transcription"); return nil
        })
        require(false, "chat-only model must not upload audio")
    } catch let error as AITranscriptionError { require(error == .configuration, "unsupported model rejected") }
    require(FixtureProtocol.requests == invalidRequests, "unsupported model sends no request")
    let before = FixtureProtocol.requests
    do { _ = try await client.transcribe(audio: audio, connection: connection, readKey: { _ in nil }); require(false, "missing credential") }
    catch let error as AITranscriptionError { require(error == .missingKey, "typed missing credential") }
    require(FixtureProtocol.requests == before, "missing key cannot send audio")
    let cancelled = Task { try await client.transcribe(audio: audio, connection: connection, readKey: { _ in "fixture-key" }) }
    cancelled.cancel()
    do { _ = try await cancelled.value; require(false, "cancelled request") }
    catch is CancellationError {}
    require(FixtureProtocol.requests == before, "cancelled request cannot send audio")
    print("Dictation transport fixtures passed; uploads used synthetic audio and simulated responses, with no microphone, real credentials or clipboard.")
}

Task {
    do { try await run(); exit(0) }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
dispatchMain()
