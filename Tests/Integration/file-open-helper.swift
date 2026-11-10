import AppKit
final class Helper: NSObject, NSApplicationDelegate {
    func application(_ sender:NSApplication,openFiles filenames:[String]) {
        let receipt = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("receipt.json")
        do { try JSONSerialization.data(withJSONObject:filenames).write(to:receipt,options:.atomic); sender.reply(toOpenOrPrint:.success) }
        catch { sender.reply(toOpenOrPrint:.failure) }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { sender.terminate(nil) }
    }
}
let delegate = Helper()
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
