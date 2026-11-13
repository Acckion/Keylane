import AppKit
import Combine
import Darwin
import Foundation
import KeylaneCore

final class Delegate: NSObject, NSApplicationDelegate {
    let window: NSWindow? = nil
    let toast = Toast()
    func hideLauncher() {}
}
final class Toast {
    enum Style { case success, failure }
    private(set) var latest: (String, Style)?
    func show(_ text: String, style: Style) { latest = (text, style) }
}

let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
let root = base.appendingPathComponent("scripts", isDirectory: true)
let marker = base.appendingPathComponent("runs")
let finished = base.appendingPathComponent("finished")
let processID = base.appendingPathComponent("pid")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
let suite = "org.keylane.scripts.fixture.\(UUID())"
let preferences = UserDefaults(suiteName: suite)!
defer { preferences.removePersistentDomain(forName: suite) }
preferences.set([root.path], forKey: "scriptCommands.folders")
let delegate = Delegate()
NSApplication.shared.delegate = delegate
let controller = ScriptCommandsController(preferences: preferences)
var scans = 0
let scanning = controller.$scanning.sink { if $0 { scans += 1 } }
var outputUpdates = 0
let output = controller.$inlineOutput.dropFirst().sink { _ in outputUpdates += 1 }

func advance(_ duration: TimeInterval) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: duration))
}
func wait(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while !condition(), ProcessInfo.processInfo.systemUptime < deadline { advance(0.025) }
    return condition()
}
func write(_ name: String, _ script: String) throws {
    try script.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
}
func writeSilent(_ name: String) throws {
    try write("\(name).sh", """
    #!/bin/sh
    # @raycast.schemaVersion 1
    # @raycast.title \(name)
    # @raycast.mode silent
    exit 0
    """)
}
func starts() -> Int {
    ((try? String(contentsOf: marker, encoding: .utf8)) ?? "").split(separator: "\n").count
}
controller.start()
precondition(wait(4) { !controller.scanning && scans == 1 })
controller.setLauncherVisible(true)
advance(2)
precondition(scans == 1, "opening an unchanged catalog rescanned")
try write("inline.sh", """
#!/bin/sh
# @raycast.schemaVersion 1
# @raycast.title Fixture Inline
# @raycast.mode inline
# @raycast.refreshTime 10s
printf 'start\\n' >> '\(marker.path)'
if [ "$(wc -l < '\(marker.path)')" -gt 2 ]; then
    printf '%s\\n' "$$" > '\(processID.path)'
    /bin/sleep 6
    touch '\(finished.path)'
fi
printf 'constant output\\n'
""")
try write("foreground.sh", """
#!/bin/sh
# @raycast.schemaVersion 1
# @raycast.title Fixture Foreground
# @raycast.mode compact
printf 'manual output\\n'
""")
precondition(wait(5) { controller.entries.count == 2 && !controller.scanning })
precondition(scans == 2, "neighboring writes did not coalesce")
let dependencies = root.appendingPathComponent("node_modules", isDirectory: true)
try FileManager.default.createDirectory(at: dependencies, withIntermediateDirectories: false)
try "#!/bin/sh\nexit 0".write(to: dependencies.appendingPathComponent("ignored.sh"), atomically: true, encoding: .utf8)
advance(1.6)
precondition(scans == 2, "ignored dependency changes caused a scan")
print("PASS recursive FSEvents discovery, event coalescing, ignored directories, and no scan on reveal")
let inline = controller.entries.first { $0.title == "Fixture Inline" }!
let manual = controller.entries.first { $0.title == "Fixture Foreground" }!
controller.select(inline)
controller.run()
precondition(wait(3) { !controller.running && starts() == 1 && controller.inlineOutput[inline.id] == "constant output" })
precondition(wait(13) { starts() == 2 })
advance(0.4)
precondition(outputUpdates == 1 && scans == 2, "constant output caused UI invalidation or unrelated writes caused a scan")
func runningPID() -> pid_t? {
    (try? String(contentsOf: processID, encoding: .utf8)).flatMap {
        pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
precondition(wait(13) { starts() == 3 && runningPID() != nil })
let preempted = runningPID()!
precondition(!controller.running, "background work surfaced as a foreground run")
controller.select(manual)
controller.run()
precondition(wait(2) { !controller.running && controller.result?.output == "manual output\n" })
precondition(kill(preempted, 0) == -1 && !FileManager.default.fileExists(atPath: finished.path))
precondition(wait(2) { starts() == 4 && runningPID().map { $0 != preempted } == true }, "interrupted job did not become eligible again")
let hidden = runningPID()!
controller.setLauncherVisible(false)
precondition(wait(2) { kill(hidden, 0) == -1 })
precondition(starts() == 4 && !FileManager.default.fileExists(atPath: finished.path))
print("PASS inline scheduling, identical output suppression, foreground priority, and background cancellation on hide")
controller.enabled = false
let scansBeforeDisable = scans
try writeSilent("another")
advance(1.8)
precondition(scans == scansBeforeDisable)
controller.enabled = true
precondition(wait(5) { controller.entries.count == 3 && !controller.scanning })
let original = base.appendingPathComponent("previous")
try FileManager.default.moveItem(at: root, to: original)
precondition(wait(5) { controller.entries.isEmpty && !controller.scanning })
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
try writeSilent("replacement")
precondition(wait(5) { controller.entries.map(\.title) == ["replacement"] && !controller.scanning })
try write("long.sh", """
#!/bin/sh
# @raycast.schemaVersion 1
# @raycast.title Long Foreground
# @raycast.mode fullOutput
printf '%s\\n' "$$" > '\(processID.path)'
/bin/sleep 30
""")
try FileManager.default.removeItem(at: processID)
precondition(wait(5) { controller.entries.contains { $0.title == "Long Foreground" } })
let long = controller.entries.first { $0.title == "Long Foreground" }!
controller.select(long)
controller.run()
precondition(wait(4) { controller.running && runningPID() != nil })
let stoppedProcess = runningPID()!
controller.stop()
precondition(!controller.running && controller.entries.isEmpty && !controller.canRun(long))
precondition(wait(3) { kill(stoppedProcess, 0) == -1 })
let scansWhileStopped = scans
try writeSilent("after-stop")
advance(1.8)
precondition(scans == scansWhileStopped && controller.result == nil)
controller.start()
precondition(wait(5) { controller.entries.contains { $0.title == "after-stop" } && controller.canRun(long) })
// Verify that partial output stays available without masking why a run ended.
try write("interrupted.sh", """
#!/bin/sh
# @keylane.schemaVersion 1
# @keylane.title Interrupted
# @keylane.mode compact
# @keylane.currentDirectoryPath workspace
printf '%s\\n' "$PWD" "$LANG" "$TERM"
printf 'Started\\n'
/bin/sleep 30
""")
let workingDirectory = root.appendingPathComponent("workspace", isDirectory: true)
try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: false)
precondition(wait(5) { controller.entries.contains { $0.title == "Interrupted" } })
let interrupted = controller.entries.first { $0.title == "Interrupted" }!
controller.select(interrupted)
precondition(controller.directory == workingDirectory.path)
controller.timeout = "1"
controller.run()
precondition(wait(4) { controller.result?.status == .timedOut })
let partial = controller.result!.output
let lines = partial.split(separator: "\n")
precondition(lines.count == 4)
let actualDirectory = URL(fileURLWithPath: String(lines[0]), isDirectory: true)
precondition(actualDirectory.resolvingSymlinksInPath() == workingDirectory.resolvingSymlinksInPath())
precondition(Array(lines.dropFirst()) == ["en_US.UTF-8", "linux", "Started"])
precondition(delegate.toast.latest?.0 == "脚本运行超时" && delegate.toast.latest?.1 == .failure,
             "partial output masked the timeout")
controller.run()
controller.cancel()
precondition(wait(3) { controller.result?.status == .cancelled })
precondition(delegate.toast.latest?.0 == "已取消脚本运行")
let pasteboard = NSPasteboard.withUniqueName()
defer { pasteboard.releaseGlobally() }
let limited = String(repeating: "x", count: 262_143)
try write("long-output.sh", """
#!/bin/sh
# @keylane.schemaVersion 1
# @keylane.title Long Output
# @keylane.mode fullOutput
/usr/bin/head -c 262143 /dev/zero | /usr/bin/tr '\\000' x
printf '%s' '中'
""")
precondition(wait(5) { controller.entries.contains { $0.title == "Long Output" } })
controller.select(controller.entries.first { $0.title == "Long Output" }!)
controller.run()
precondition(wait(5) { controller.result?.truncated == true })
let copyText = ScriptOutputText.plain(controller.result!.output)
precondition(pasteboard.setString(copyText, forType: .string))
precondition(pasteboard.string(forType: .string) == limited)
print("PASS relative working directory, inherited LANG, default TERM, timeout, cancel, and truncated output on a named pasteboard")
// Modify and rename a nested command while the watcher is running.
let nested = root.appendingPathComponent("nested", isDirectory: true)
try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
let source = nested.appendingPathComponent("command.sh")
func writeNested(title: String, extra: String = "") throws {
    try """
    #!/bin/sh
    # @raycast.schemaVersion 1
    # @raycast.title Legacy
    # @raycast.mode silent
    # @keylane.title \(title)
    \(extra)
    /usr/bin/touch '\(finished.path)'
    """.write(to: source, atomically: true, encoding: .utf8)
}
try writeNested(title: "Original Title")
precondition(wait(5) { controller.entries.contains { $0.title == "Original Title" } })
let oldID = controller.entries.first { $0.title == "Original Title" }!.id
try writeNested(title: "Updated Title")
precondition(wait(5) { controller.command(withID: oldID)?.title == "Updated Title" })
let renamed = nested.appendingPathComponent("renamed.sh")
try FileManager.default.moveItem(at: source, to: renamed)
precondition(wait(5) {
    controller.command(withID: oldID) == nil && controller.entries.contains { $0.url == renamed && $0.title == "Updated Title" }
})
try writeNested(title: "Windows only", extra: "# @raycast.platform windows")
try write("unmarked.sh", "#!/bin/sh\nexit 0")
try FileManager.default.removeItem(at: renamed)
precondition(wait(5) { !controller.entries.contains { $0.url == renamed } })
precondition(controller.entries.allSatisfy { $0.url != source && $0.url.lastPathComponent != "unmarked.sh" })
precondition(!FileManager.default.fileExists(atPath: finished.path))
controller.removeFolder(root.path)
precondition(wait(5) { controller.entries.isEmpty && !controller.scanning })
print("PASS mixed metadata, recursive edits, rename identity, platform filtering, and scope removal")
controller.stop()
withExtendedLifetime((scanning, output)) {}
print("PASS stopping discovery while disabled, re-enabling, and replacing a watched root")
