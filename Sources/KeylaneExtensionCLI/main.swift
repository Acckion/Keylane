import Darwin
import Foundation
import KeylaneCore

let usage = """
Usage:
  keylane-extension validate <local-source-directory>
  keylane-extension commands <local-source-directory>

Inspects Raycast source metadata without executing extension code.
"""

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] || arguments == ["-h"] {
    print(usage)
    exit(0)
}

guard arguments.count == 2, ["validate", "commands"].contains(arguments[0]) else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}

do {
    let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let manifest = try RaycastExtensionManifest.read(directory: directory)
    if arguments[0] == "validate" {
        print("Valid source metadata: \(manifest.author)/\(manifest.name) (\(manifest.commands.count) commands)")
    } else {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(manifest) + Data([10]))
    }
} catch {
    let message: String
    if let decoding = error as? DecodingError {
        message = "Invalid package.json: \(decoding)"
    } else {
        message = error.localizedDescription
    }
    FileHandle.standardError.write(Data(("keylane-extension: " + message + "\n").utf8))
    exit(1)
}
