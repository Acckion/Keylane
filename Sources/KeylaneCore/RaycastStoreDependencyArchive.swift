import Foundation
import zlib

/// Integrity-checked inert package data. Not a build/launch authorization. No
/// filesystem extraction or executable invocation is performed by this type.
public struct RaycastStoreDependencyArchive: Sendable {
    public enum Failure: Error, Equatable {
        case integrity, blockedDependency, compression, limit, malformedTar
        case unsupportedEntry, unsafePath, duplicatePath, nativeContent, manifest
        case lifecycleScript(String), runtimeEntry, dependencyLockMismatch
    }
    public let installationPath: String
    public let name: String
    public let version: String
    /// Keys are package-relative, not host paths; caller must retain installationPath.
    public let files: [String: Data]
    /// Published-registry authoring hook only; never invoked during data staging.
    public let hasInertPrepareMetadata: Bool
    public init(tarball: Data, node: RaycastStoreDependencyPlan.Node, target: RaycastStoreBuildDependencies.Target = .linuxArm64) throws {
        guard node.verifiesTarball(tarball) else { throw Failure.integrity }
        guard node.permits(target), node.blockers(for: target).isEmpty else { throw Failure.blockedDependency }
        let tar = try Self.inflate(tarball)
        let files = try Self.readTar(tar)
        guard let data = files["package.json"], data.count <= 1024 * 1024,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.name == node.name, manifest.version == node.version,
              manifest.gypfile != true, Self.permits(target.os, manifest.os), Self.permits(target.cpu, manifest.cpu),
              manifest.bundleDependencies == nil, manifest.bundledDependencies == nil else { throw Failure.manifest }
        guard RaycastStoreDependencyPlan.matchesRuntimeDeclarations(node.edges, dependencies: manifest.dependencies ?? [:],
            optional: manifest.optionalDependencies ?? [:], peers: manifest.peerDependencies ?? [:],
            optionalPeers: Set((manifest.peerDependenciesMeta ?? [:]).filter { $0.value.optional == true }.keys)) else {
            throw Failure.dependencyLockMismatch
        }
        if let hook = ["preinstall", "install", "postinstall"].first(where: { manifest.scripts?[$0] != nil }) {
            throw Failure.lifecycleScript(hook)
        }
        // Do not resolve Node conditions or guess generated output. Every concrete
        // declared export must already exist; wildcard/directory targets fail closed.
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var targets: [String] = []
        func exports(_ value: Any, depth: Int) throws {
            guard depth <= 16, targets.count <= 256 else { throw Failure.runtimeEntry }
            if value is NSNull { return }
            if let value = value as? String { targets.append(value); return }
            if let values = value as? [String: Any] { for value in values.values { try exports(value, depth: depth + 1) }; return }
            if let values = value as? [Any] { for value in values { try exports(value, depth: depth + 1) }; return }
            throw Failure.runtimeEntry
        }
        if let value = raw["exports"] { try exports(value, depth: 0) }
        for key in ["main", "module"] {
            if let value = raw[key] { guard let path = value as? String else { throw Failure.runtimeEntry }; targets.append(path) }
        }
        if targets.isEmpty { targets = ["index.js"] }
        guard targets.count <= 256 else { throw Failure.runtimeEntry }
        for target in targets {
            let path = target.hasPrefix("./") ? String(target.dropFirst(2)) : target
            guard !path.contains("*"), files[path] != nil else { throw Failure.runtimeEntry }
        }
        hasInertPrepareMetadata = manifest.scripts?["prepare"] != nil
        installationPath = node.path; name = node.name; version = node.version; self.files = files
    }
    private struct Manifest: Decodable {
        struct PeerMetadata: Decodable { let optional: Bool? }
        let dependencies: [String: String]?
        let optionalDependencies: [String: String]?
        let peerDependencies: [String: String]?
        let peerDependenciesMeta: [String: PeerMetadata]?
        let name: String; let version: String; let scripts: [String: String]?
        let gypfile: Bool?; let os: [String]?; let cpu: [String]?
        let bundleDependencies: [String]?; let bundledDependencies: [String]?
    }
    private static func permits(_ value: String, _ restrictions: [String]?) -> Bool {
        guard let restrictions else { return true }
        return !restrictions.contains("!" + value) && (restrictions.allSatisfy { $0.hasPrefix("!") } || restrictions.contains(value))
    }
    private static func inflate(_ input: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.compression }
        defer { inflateEnd(&stream) }
        return try input.withUnsafeBytes { source in
            stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var result = Data(), status: Int32 = Z_OK
            repeat {
                var buffer = [UInt8](repeating: 0, count: 32768)
                let produced = buffer.withUnsafeMutableBytes { out -> Int in
                    stream.next_out = out.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = 32768
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    return 32768 - Int(stream.avail_out)
                }
                guard status == Z_OK || status == Z_STREAM_END, produced > 0 || status == Z_STREAM_END else { throw Failure.compression }
                guard result.count + produced <= 32 * 1024 * 1024 else { throw Failure.limit }
                result.append(contentsOf: buffer.prefix(produced))
            } while status != Z_STREAM_END
            // Reject concatenated gzip members and opaque trailers.
            guard stream.avail_in == 0 else { throw Failure.compression }
            return result
        }
    }
    private static func readTar(_ data: Data) throws -> [String: Data] {
        guard data.count % 512 == 0 else { throw Failure.malformedTar }
        var offset = 0, entries = 0, files: [String: Data] = [:], seen = Set<String>(), filePaths = Set<String>()
        func string(_ bytes: ArraySlice<UInt8>) throws -> String {
            let raw = Array(bytes), end = raw.firstIndex(of: 0) ?? raw.count
            guard raw.dropFirst(end).allSatisfy({ $0 == 0 }), let value = String(bytes: raw.prefix(end), encoding: .utf8) else { throw Failure.malformedTar }
            return value
        }
        func octal(_ bytes: ArraySlice<UInt8>) throws -> Int {
            let value = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) ?? ""
            guard !value.isEmpty, value.allSatisfy({ "01234567".contains($0) }), let number = Int(value, radix: 8) else { throw Failure.malformedTar }
            return number
        }
        while offset + 512 <= data.count {
            let header = Array(data[offset..<offset + 512])
            if header.allSatisfy({ $0 == 0 }) {
                guard offset + 1024 <= data.count, data[offset...].allSatisfy({ $0 == 0 }) else { throw Failure.malformedTar }
                // Files cannot shadow directory parents (including implicit ones).
                for path in files.keys {
                    var parts = path.split(separator: "/"); parts.removeLast()
                    while !parts.isEmpty {
                        guard !filePaths.contains(parts.joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()) else { throw Failure.unsafePath }
                        parts.removeLast()
                    }
                }
                return files
            }
            entries += 1; guard entries <= 4096 else { throw Failure.limit }
            var checksum = header; checksum.replaceSubrange(148..<156, with: repeatElement(UInt8(32), count: 8))
            guard try octal(header[148..<156]) == checksum.reduce(0, { $0 + Int($1) }) else { throw Failure.malformedTar }
            let magic = try string(header[257..<263])
            guard magic == "ustar" || magic == "ustar " || magic.isEmpty else { throw Failure.unsupportedEntry }
            let type = header[156]
            guard type == 0 || type == 48 || type == 53 else { throw Failure.unsupportedEntry }
            guard try string(header[157..<257]).isEmpty else { throw Failure.unsupportedEntry }
            var path = try string(header[0..<100])
            let prefix = try string(header[345..<500])
            if !prefix.isEmpty { path = prefix + "/" + path }
            if type == 53, path.hasSuffix("/") { path.removeLast() }
            let size = try octal(header[124..<136])
            guard size <= 8 * 1024 * 1024 else { throw Failure.limit }
            guard path.utf8.count <= 1024, !path.contains("\\"), !path.contains(":"),
                  !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw Failure.unsafePath }
            let parts = path.components(separatedBy: "/")
            guard parts.first == "package", parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  type == 53 || parts.count > 1 else { throw Failure.unsafePath }
            let relative = parts.dropFirst().joined(separator: "/")
            let folded = relative.precomposedStringWithCanonicalMapping.lowercased()
            guard seen.insert(folded).inserted else { throw Failure.duplicatePath }
            let lower = relative.lowercased()
            guard !parts.contains("node_modules"), ![".node", ".so", ".dylib", ".dll", ".exe", ".a", ".o"].contains(where: { lower.hasSuffix($0) }),
                  parts.last?.lowercased() != "binding.gyp" else { throw Failure.nativeContent }
            let padded = ((size + 511) / 512) * 512
            guard offset + 512 + padded <= data.count else { throw Failure.malformedTar }
            if type == 53 {
                guard size == 0 else { throw Failure.malformedTar }
            } else {
                let bytes = data.subdata(in: offset + 512..<offset + 512 + size)
                // Reject common native executable magic even if extension is disguised.
                let magic = Array(bytes.prefix(4))
                guard magic != [0x7f, 0x45, 0x4c, 0x46], ![[0xcf,0xfa,0xed,0xfe], [0xce,0xfa,0xed,0xfe], [0xfe,0xed,0xfa,0xcf], [0xca,0xfe,0xba,0xbe], [0xbe,0xba,0xfe,0xca], [0xfe,0xed,0xfa,0xce], [0xca,0xfe,0xba,0xbf], [0xbf,0xba,0xfe,0xca]].contains(magic),
                      Array(bytes.prefix(2)) != [0x4d,0x5a] else { throw Failure.nativeContent }
                files[relative] = bytes; filePaths.insert(folded)
            }
            offset += 512 + padded
        }
        throw Failure.malformedTar
    }
}
