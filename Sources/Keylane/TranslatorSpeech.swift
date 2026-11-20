import AppKit
import AVFoundation
import Combine
import Speech

final class TranslatorSpeech: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var error = ""
    private let speaker = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var tapInstalled = false
    private var generation = 0

    func speak(_ text: String, language: String) {
        if recording { stop() }
        speaker.stopSpeaking(at: .immediate)
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language == "auto" ? Locale.current.identifier : language)
        speaker.speak(utterance)
    }

    func toggle(language: String, update: @escaping (String) -> Void) {
        if recording { stop(); return }
        generation += 1
        let ticket = generation
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                DispatchQueue.main.async {
                    guard let self, ticket == self.generation else { return }
                    self.error = "请在系统设置中允许 Keylane 使用语音识别。"
                }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { microphone in
                DispatchQueue.main.async {
                    guard let self, ticket == self.generation else { return }
                    guard status == .authorized, microphone else {
                        self.error = "请在系统设置中允许 Keylane 使用麦克风与语音识别。"
                        return
                    }
                    self.start(language: language, update: update)
                }
            }
        }
    }

    private func start(language: String, update: @escaping (String) -> Void) {
        error = ""
        let locale = language == "auto" ? Locale.current : Locale(identifier: language)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            error = "此语言的语音识别当前不可用。"
            return
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { error = "没有可用的麦克风。"; return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        tapInstalled = true
        let ticket = generation
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, failure in
            DispatchQueue.main.async {
                guard let self, self.generation == ticket else { return }
                if let result { update(result.bestTranscription.formattedString) }
                if failure != nil || result?.isFinal == true { self.stop() }
            }
        }
        do { try engine.start(); recording = true }
        catch { stop(); self.error = "无法启动麦克风。" }
    }

    func dismissError() { error = "" }

    func stop() {
        generation += 1
        speaker.stopSpeaking(at: .immediate)
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio()
        recognition?.cancel()
        request = nil
        recognition = nil
        recognizer = nil
        recording = false
    }
}
