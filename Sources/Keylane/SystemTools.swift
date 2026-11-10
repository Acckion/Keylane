import AppKit
import ApplicationServices
import AVFoundation

final class SystemTools {
    static let shared = SystemTools()
    private let speaker = AVSpeechSynthesizer()
    func readClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        speaker.stopSpeaking(at: .immediate); speaker.speak(AVSpeechUtterance(string: text))
    }
    func stopReading() { speaker.stopSpeaking(at: .immediate) }
    func colorPicker() {
        NSColorSampler().show { color in guard let color = color?.usingColorSpace(.sRGB) else { return }; let hex = String(format: "#%02X%02X%02X", Int(color.redComponent*255),Int(color.greenComponent*255),Int(color.blueComponent*255)); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(hex, forType: .string) }
    }
    func screenshot() {
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); task.arguments = ["-i", "-c"]
        do { try task.run() } catch { NSAlert(error: error).runModal() }
    }
}
