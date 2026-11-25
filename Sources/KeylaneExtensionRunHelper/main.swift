import Darwin
import Foundation
import JavaScriptCore
import Security

private let maximumSourceBytes = 4 * 1024 * 1024

private func evaluate() throws -> Bool {
    var coreLimit = rlimit(rlim_cur: 0, rlim_max: 0)
    guard setrlimit(RLIMIT_CORE, &coreLimit) == 0, fcntl(3, F_GETFD) >= 0 else { return false }
    // The watcher runs independently of the JavaScript thread, including
    // during input reads and uninterruptible JavaScript evaluation.
    var watcher: pthread_t?
    guard pthread_create(&watcher, nil, { _ in
        var byte: UInt8 = 0
        while Darwin.read(3, &byte, 1) < 0 && errno == EINTR {}
        _exit(70)
    }, nil) == 0, let watcher else { return false }
    pthread_detach(watcher)
    alarm(6)

    var input = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 65536), !chunk.isEmpty {
        guard chunk.count <= 8 * 1024 * 1024 - input.count else { return false }
        input.append(chunk)
    }
    guard let request = try JSONSerialization.jsonObject(with: input) as? [String: Any],
          let script = request["source"] as? String, !script.isEmpty, script.utf8.count <= maximumSourceBytes,
          let preferences = request["preferences"] as? [String: Any],
          let toast = request["toast"] as? Bool, let clipboard = request["clipboard"] as? Bool,
          let context = JSContext() else { return false }
    context.isInspectable = false
    var failed = false
    var effects: [[String: String]] = []
    context.exceptionHandler = { _, _ in failed = true }

    func frozenRecord(_ record: Any) throws -> JSValue? {
        let data = try JSONSerialization.data(withJSONObject: record)
        guard data.count <= 4096 else { return nil }
        let literal = try JSONEncoder().encode(String(decoding: data, as: UTF8.self))
        return context.evaluateScript("Object.freeze(JSON.parse(" + String(decoding: literal, as: UTF8.self) + "))")
    }
    let arguments: [String: String]
    if let supplied = request["arguments"] {
        guard let values = supplied as? [String: String] else { return false }
        arguments = values
    } else {
        arguments = [:]
    }
    let environment: [String: String]
    if let supplied = request["environment"] {
        guard let fields = supplied as? [String: String],
              Set(fields.keys).isSubset(of: ["ownerOrAuthorName", "extensionName", "entryPointName", "appearance", "textSize"]),
              fields["appearance"].map({ ["dark", "light"].contains($0) }) ?? true,
              fields["textSize"].map({ ["medium", "large"].contains($0) }) ?? true else { return false }
        environment = fields
    } else {
        environment = [:]
    }
    guard let environmentObject = try frozenRecord(environment),
          let api = JSValue(newObjectIn: context),
          let preferenceObject = try frozenRecord(preferences),
          let argumentObject = try frozenRecord(arguments) else { return false }
    api.setObject(environmentObject, forKeyedSubscript: "environment" as NSString)
    api.setObject(preferenceObject, forKeyedSubscript: "preferences" as NSString)

    func enqueue(_ kind: String, _ limit: Int) -> @convention(block) (JSValue) -> Bool {
        { argument in
            guard argument.isString, let text = argument.toString(), text.utf8.count <= limit,
                  effects.count < 8 else { return false }
            effects.append(["kind": kind, "value": text])
            return true
        }
    }

    if toast { api.setObject(enqueue("toast", 4096), forKeyedSubscript: "toast" as NSString) }
    if clipboard { api.setObject(enqueue("copy", 4096), forKeyedSubscript: "copy" as NSString) }
    if let closeWindow = request["closeWindow"] {
        guard let allowed = closeWindow as? Bool else { return false }
        if allowed { api.setObject(enqueue("close", 15), forKeyedSubscript: "closeWindow" as NSString) }
    }
    for kind in ["clearSearch", "popToRoot"] {
        if let provided = request[kind] {
            guard let allowed = provided as? Bool else { return false }
            if allowed { api.setObject(enqueue(kind, 5), forKeyedSubscript: kind as NSString) }
        }
    }
    context.setObject(api, forKeyedSubscript: "keylane" as NSString)
    context.evaluateScript("Object.freeze(globalThis.keylane)")
    // JavaScriptCore has typed arrays but does not supply the web UTF-8 encoder.
    context.evaluateScript("""
        if (typeof globalThis.TextEncoder === "undefined") {
          globalThis.TextEncoder = class TextEncoder {
            get encoding() { return "utf-8"; }
            encode(input = "") {
              const bytes = [];
              for (const character of String(input)) {
                let code = character.codePointAt(0);
                if (code >= 0xd800 && code <= 0xdfff) code = 0xfffd;
                if (code < 0x80) {
                  bytes.push(code);
                } else if (code < 0x800) {
                  bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
                } else if (code < 0x10000) {
                  bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
                } else {
                  bytes.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 0x3f),
                             0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
                }
              }
              return Uint8Array.from(bytes);
            }
          };
        }
        """)
    // Capture the Promise and property primitives before running guest code.
    // Calling through JavaScriptCore services resolved Promise jobs; this
    // runtime supplies no external event source for a promise left pending.
    let invokeCommand = context.evaluateScript("""
        (() => {
            const hasOwn = Function.prototype.call.bind(Object.prototype.hasOwnProperty);
            const freeze = Object.freeze;
            const resolve = Promise.resolve.bind(Promise);
            const then = Function.prototype.call.bind(Promise.prototype.then);
            return (exports, args, expectsCommand, finish) => {
                if (exports == null || !hasOwn(exports, "default")) {
                    finish(!expectsCommand);
                    return;
                }
                const command = exports.default;
                if (typeof command !== "function") {
                    finish(false);
                    return;
                }
                then(resolve(command(freeze({ arguments: args, launchType: "userInitiated" }))), () => finish(true), () => finish(false));
            };
        })()
        """)
    context.evaluateScript(script)
    guard !failed, let invokeCommand,
          let namespace = context.objectForKeyedSubscript("__keylaneCommandExports") else { return false }
    var completed = false
    let finish: @convention(block) (Bool) -> Void = { success in completed = success }
    guard let callback = JSValue(object: finish, in: context) else { return false }
    invokeCommand.call(withArguments: [namespace, argumentObject, !arguments.isEmpty, callback])
    guard !failed, completed else { return false }
    let output = try JSONSerialization.data(withJSONObject: ["effects": effects])
    guard output.count <= 65536 else { return false }
    try FileHandle.standardOutput.write(contentsOf: output)
    return true
}

exit((try? evaluate()) == true ? 0 : 71)
