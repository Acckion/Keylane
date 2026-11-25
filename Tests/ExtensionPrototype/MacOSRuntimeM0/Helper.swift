import Foundation

// First-party feasibility fixture only. Never registered in the product catalog.
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let node = root.appendingPathComponent("node")
let process = Process()
process.executableURL = node
process.arguments = ["--max-old-space-size=64", "-"]
process.environment = [
    "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory(),
    "KEYLANE_M0_CONTAINER": NSHomeDirectory(),
]
process.standardInput = FileHandle.standardInput
process.standardOutput = FileHandle.standardOutput
process.standardError = FileHandle.standardError
// launch/run failures remain failures; never fall back to an unsandboxed runtime.
do {
    try process.run()
    process.waitUntilExit()
    exit(process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus)
} catch {
    FileHandle.standardError.write(Data("M0 node launch failed\n".utf8))
    exit(70)
}
