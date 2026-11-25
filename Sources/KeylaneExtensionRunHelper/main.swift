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
    if CommandLine.arguments == [CommandLine.arguments[0], "--reviewed-view-session"] {
        return try ViewSession.run()
    }
    guard CommandLine.arguments.count == 1 else { return false }
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
              Set(fields.keys).isSubset(of: ["ownerOrAuthorName", "extensionName", "entryPointName", "appearance", "textSize", "raycastVersion"]),
              fields["raycastVersion"].map({ !$0.isEmpty && $0.utf8.count <= 64 }) ?? true,
              fields["appearance"].map({ ["dark", "light"].contains($0) }) ?? true,
              fields["textSize"].map({ ["medium", "large"].contains($0) }) ?? true else { return false }
        environment = fields
    } else {
        environment = [:]
    }
    let preferenceFields = request["preferenceFields"] ?? []
    guard let fields = preferenceFields as? [[String: Any]], fields.count <= 32,
          let fieldsObject = try frozenRecord(fields),
          let environmentObject = try frozenRecord(environment),
          let api = JSValue(newObjectIn: context),
          let preferenceObject = try frozenRecord(preferences),
          let argumentObject = try frozenRecord(arguments) else { return false }
    api.setObject(environmentObject, forKeyedSubscript: "environment" as NSString)
    api.setObject(preferenceObject, forKeyedSubscript: "preferences" as NSString)
    api.setObject(fieldsObject, forKeyedSubscript: "preferenceFields" as NSString)

    func checkedPath(_ path: String, root: String, maximumBytes: Int) -> Bool {
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        return path.hasPrefix(root + "/") && path.utf8.count <= maximumBytes &&
            !path.contains("\\") && !path.contains("\0") &&
            parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    func decodeFiles(_ value: Any, root: String, maximumFiles: Int, maximumBytes: Int, maximumPathBytes: Int) -> [String: Data]? {
        guard let encoded = value as? [String: String], encoded.count <= maximumFiles else { return nil }
        var files: [String: Data] = [:], byteCount = 0
        for (path, value) in encoded {
            guard checkedPath(path, root: root, maximumBytes: maximumPathBytes),
                  let data = Data(base64Encoded: value), data.count <= maximumBytes - byteCount else { return nil }
            files[path] = data
            byteCount += data.count
        }
        return files
    }

    func readFile(_ data: Data?, text: Bool) -> NSObject? {
        guard let data else { return nil }
        if text { return String(decoding: data, as: UTF8.self) as NSString }
        return data.map { NSNumber(value: $0) } as NSArray
    }

    if let rawAssets = request["packagedAssets"] {
        guard let assets = decodeFiles(rawAssets, root: "/assets", maximumFiles: 128,
                                       maximumBytes: 512 * 1024, maximumPathBytes: 1025) else { return false }
        let read: @convention(block) (JSValue, Bool) -> NSObject? = { path, text in
            guard path.isString, let key = path.toString(), key.utf8.count <= 1025 else { return nil }
            return readFile(assets[key], text: text)
        }
        api.setObject(read, forKeyedSubscript: "readAsset" as NSString)
    }

    let cacheEnabled = request["cacheSnapshot"] != nil
    var supportUpdate: [String: Data]?
    if let input = request["supportFiles"] {
        guard var files = decodeFiles(input, root: "/support", maximumFiles: 32,
                                      maximumBytes: 32 * 1024, maximumPathBytes: 256) else { return false }
        var bytes = files.values.reduce(0) { $0 + $1.count }
        let read: @convention(block) (JSValue, Bool) -> NSObject? = { path, text in
            guard path.isString, let key = path.toString(), key.utf8.count <= 256 else { return nil }
            return readFile(files[key], text: text)
        }
        let write: @convention(block) (JSValue, JSValue) -> Bool = { path, value in
            guard path.isString, let key = path.toString(), checkedPath(key, root: "/support", maximumBytes: 256),
                  !cacheEnabled || !key.hasSuffix("/cache/entries.json"),
                  value.isArray, let length = value.forProperty("length")?.toUInt32(),
                  files[key] != nil || files.count < 32 else { return false }
            let otherBytes = bytes - (files[key]?.count ?? 0)
            guard Int(length) <= 32 * 1024 - otherBytes else { return false }
            var data = Data(capacity: Int(length))
            for index in 0..<Int(length) {
                guard let item = value.atIndex(index), item.isNumber,
                      let byte = UInt8(exactly: item.toDouble()) else { return false }
                data.append(byte)
            }
            files[key] = data
            bytes = otherBytes + data.count
            supportUpdate = files
            return true
        }
        api.setObject(read, forKeyedSubscript: "readSupport" as NSString)
        api.setObject(write, forKeyedSubscript: "writeSupport" as NSString)
    }

    var cacheUpdate: Data?
    if let supplied = request["cacheSnapshot"] {
        guard let snapshot = supplied as? String, snapshot.utf8.count <= 32 * 1024 else { return false }
        api.setObject(snapshot, forKeyedSubscript: "cacheSnapshot" as NSString)
        let update: @convention(block) (JSValue) -> Bool = { value in
            guard value.isString, let snapshot = value.toString(), snapshot.utf8.count <= 32 * 1024 else { return false }
            cacheUpdate = Data(snapshot.utf8)
            return true
        }
        api.setObject(update, forKeyedSubscript: "updateCache" as NSString)
    }

    var localStorageUpdate: Data?
    if let supplied = request["localStorageSnapshot"] {
        guard let snapshot = supplied as? String, snapshot.utf8.count <= 32 * 1024 else { return false }
        api.setObject(snapshot, forKeyedSubscript: "localStorageSnapshot" as NSString)
        let update: @convention(block) (JSValue) -> Bool = { value in
            guard value.isString, let snapshot = value.toString(), snapshot.utf8.count <= 32 * 1024 else { return false }
            localStorageUpdate = Data(snapshot.utf8)
            return true
        }
        api.setObject(update, forKeyedSubscript: "updateLocalStorage" as NSString)
    }

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
    for kind in ["clearSearch", "popToRoot", "openPreferences"] {
        if let provided = request[kind] {
            guard let allowed = provided as? Bool else { return false }
            if allowed { api.setObject(enqueue(kind, kind == "openPreferences" ? 9 : 5), forKeyedSubscript: kind as NSString) }
        }
    }
    var diagnosticSamples: [[String: Any]] = []
    if let supplied = request["diagnostics"] {
        guard let allowed = supplied as? Bool else { return false }
        if allowed {
            let capture: @convention(block) (JSValue) -> Void = { kind in
                guard diagnosticSamples.count < 16, kind.isString, let category = kind.toString() else { return }
                if ["undefined", "boolean", "number", "string", "bigint", "symbol", "object", "function"].contains(category) {
                    diagnosticSamples.append(["exceptionCategory": category])
                }
            }
            let memory: @convention(block) () -> Void = {
                var usage = rusage()
                if diagnosticSamples.count < 16, getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss > 0 {
                    var sample: [String: Any] = ["peakResidentBytes": usage.ru_maxrss]
                    var info = mach_task_basic_info()
                    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
                    let status = withUnsafeMutablePointer(to: &info) { pointer in
                        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                        }
                    }
                    if status == KERN_SUCCESS, info.resident_size > 0 {
                        sample["residentBytes"] = info.resident_size
                        sample["peakResidentBytes"] = max(UInt64(usage.ru_maxrss), info.resident_size)
                    }
                    diagnosticSamples.append(sample)
                }
            }
            api.setObject(capture, forKeyedSubscript: "captureExceptionCategory" as NSString)
            api.setObject(memory, forKeyedSubscript: "captureMemoryUsage" as NSString)
        }
    }
    let randomID: @convention(block) (JSValue) -> String? = { length in
        guard length.isNumber, let size = Int(exactly: length.toDouble()),
              (0...65536).contains(size) else { return nil }
        guard size > 0 else { return "" }
        var bytes = Data(count: (size * 3 + 3) / 4)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { return nil }
        let encoded = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return String(encoded.prefix(size))
    }
    api.setObject(randomID, forKeyedSubscript: "randomID" as NSString)
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
    var response: [String: Any] = ["effects": effects]
    if !diagnosticSamples.isEmpty { response["diagnostics"] = diagnosticSamples }
    if let cacheUpdate {
        response["cache"] = cacheUpdate.base64EncodedString()
    }
    if let localStorageUpdate {
        response["localStorage"] = localStorageUpdate.base64EncodedString()
    }
    if let supportUpdate {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        response["supportFiles"] = try encoder.encode(supportUpdate).base64EncodedString()
    }
    let output = try JSONSerialization.data(withJSONObject: response, options: [.withoutEscapingSlashes])
    guard output.count <= 192 * 1024 else { return false }
    try FileHandle.standardOutput.write(contentsOf: output)
    return true
}

exit((try? evaluate()) == true ? 0 : 71)
