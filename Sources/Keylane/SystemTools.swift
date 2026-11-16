import AppKit
import AVFoundation

final class SystemTools {
    static let shared = SystemTools()
    private var speaker: AVSpeechSynthesizer?
    private var colorRevision = 0
    private var screenshotProcess: Process?

    func readClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        let speaker = self.speaker ?? AVSpeechSynthesizer()
        self.speaker = speaker
        speaker.stopSpeaking(at: .immediate)
        speaker.speak(AVSpeechUtterance(string: text))
    }

    func stopReading() { speaker?.stopSpeaking(at: .immediate) }

    func stopSystemTools() {
        stopReading()
        speaker = nil
        colorRevision += 1
    }

    func colorPicker() {
        colorRevision += 1
        let revision = colorRevision
        NSColorSampler().show { [weak self] color in
            guard self?.colorRevision == revision, let color = color?.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02X%02X%02X", Int(color.redComponent * 255),
                             Int(color.greenComponent * 255), Int(color.blueComponent * 255))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
        }
    }

    func screenshot() {
        guard screenshotProcess?.isRunning != true else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", "-c"]
        task.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                if self?.screenshotProcess === finished { self?.screenshotProcess = nil }
            }
        }
        do {
            try task.run()
            screenshotProcess = task
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func stopScreenshot() {
        if let screenshotProcess, screenshotProcess.isRunning { screenshotProcess.terminate() }
        screenshotProcess = nil
    }
}
