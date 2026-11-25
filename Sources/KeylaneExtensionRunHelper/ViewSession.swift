import Darwin
import Foundation
import JavaScriptCore

/// One command evaluation per supervised process; subsequent frames provide
/// typed event data to the same context. No native effects are exposed here.
enum ViewSession {
    private struct Request: Decodable {
        let session: UUID
        let sequence: Int
        let source: String?
        let capabilities: [String]?
        let event: Event?
    }

    private struct Event: Codable {
        enum Kind: String, Codable { case action, back, confirm, dismiss, toastAction, search }
        let kind: Kind
        let actionID: String?
        let query: String?
    }

    private struct Reply: Encodable {
        let session: UUID
        let sequence: Int
        let snapshot: String
    }

    static func run() throws -> Bool {
        var buffer = Data()
        var session: UUID?
        var sequence = 0
        guard let context = JSContext() else { return false }
        context.isInspectable = false
        var failed = false
        context.exceptionHandler = { _, _ in failed = true }
        guard let dispatch = context.evaluateScript("""
            (() => {
              const resolve = Promise.resolve.bind(Promise);
              const then = Function.prototype.call.bind(Promise.prototype.then);
              const stringify = JSON.stringify.bind(JSON);
              return (callback, event, finish) =>
                then(resolve(callback(event)), value => finish(stringify(value)), () => finish(undefined));
            })()
            """) else { return false }
        var receive: JSValue?
        var bytes = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            if count == 0 { break }
            let limit = session == nil ? 8 * 1024 * 1024 : 4096
            guard count > 0, count <= limit - buffer.count else { return false }
            buffer.append(contentsOf: bytes.prefix(count))
            guard let newline = buffer.firstIndex(of: 10) else { continue }
            guard newline == buffer.index(before: buffer.endIndex), sequence < 128 else { return false }
            let request = try JSONDecoder().decode(Request.self, from: buffer[..<newline])
            buffer.removeAll(keepingCapacity: false)
            guard request.sequence == sequence else { return false }
            // Bound CPU time for each request. The parent owns the overall
            // deadline and the lifetime FD even while waiting for input.
            alarm(5)
            let callback: JSValue
            let event: [String: String]
            if let session {
                guard session == request.session, request.source == nil, request.capabilities == nil, let input = request.event,
                      let receive, ((input.kind == .action || input.kind == .toastAction || input.kind == .search) == (input.actionID != nil)),
                      (input.kind == .search) == (input.query != nil),
                      (input.query?.utf8.count ?? 0) <= 256,
                      input.actionID.map({ !$0.isEmpty && $0.utf8.count <= 96 }) ?? true else { return false }
                callback = receive
                var payload = ["kind": input.kind.rawValue]
                payload["actionID"] = input.actionID
                payload["query"] = input.query
                event = payload
            } else {
                guard request.event == nil, let source = request.source, !source.isEmpty,
                      source.utf8.count <= 4 * 1024 * 1024 else { return false }
                let capabilities = request.capabilities ?? []
                guard capabilities.count <= 8, capabilities.allSatisfy({ $0.utf8.count <= 64 }) else { return false }
                session = request.session
                context.setObject(capabilities, forKeyedSubscript: "__keylaneViewCapabilities" as NSString)
                context.evaluateScript(source)
                guard !failed, let exports = context.objectForKeyedSubscript("__keylaneCommandExports"),
                      let root = exports.objectForKeyedSubscript("default"), !root.isUndefined,
                      let onEvent = exports.objectForKeyedSubscript("onEvent"), !onEvent.isUndefined else { return false }
                receive = onEvent
                callback = root
                event = [:]
            }
            var snapshot: String?
            let finish: @convention(block) (JSValue) -> Void = { result in
                if result.isString { snapshot = result.toString() }
            }
            guard let result = JSValue(object: finish, in: context) else { return false }
            dispatch.call(withArguments: [callback, event, result])
            guard !failed, let snapshot, snapshot.utf8.count <= 32 * 1024 else { return false }
            var response = try JSONEncoder().encode(Reply(session: request.session, sequence: sequence, snapshot: snapshot))
            guard response.count < 96 * 1024 else { return false }
            response.append(10)
            try FileHandle.standardOutput.write(contentsOf: response)
            alarm(0)
            sequence += 1
        }
        return session != nil && buffer.isEmpty
    }
}
