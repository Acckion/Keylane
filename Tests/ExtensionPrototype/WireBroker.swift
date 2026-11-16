import Darwin
import Foundation

@main
struct WireBroker {
    static func main() throws {
        guard CommandLine.arguments.count == 3,
              let id = UUID(uuidString: CommandLine.arguments[1]),
              let generation = UInt64(CommandLine.arguments[2]) else {
            throw ExtensionPrototypeSession.Rejection.malformed
        }
        var session = ExtensionPrototypeSession(id: id, generation: generation, grants: [.echo])
        signal(SIGPIPE, SIG_IGN)
        let input = FileHandle.standardInput
        let output = FileHandle.standardOutput
        do {
            while true {
                let chunk = input.availableData
                if chunk.isEmpty { break }
                try session.receiveBytes(chunk) { reply in
                    try output.write(contentsOf: ExtensionPrototypeSession.encode(reply, session: id, generation: generation))
                }
            }
            try session.finishInput()
        } catch {
            session.cancel()
            FileHandle.standardError.write(Data("broker: \(error)\n".utf8))
            exit(2)
        }
    }
}
