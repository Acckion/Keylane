import Foundation

/// Read-only per-invocation projection of resources authenticated by the receipt.
package enum MacOSReviewedRaycastAssets {
    static let capability = "files.assets.read"
    static let supportCapability = "files.support.write"
    static let supportLimit = 32 * 1024

    static func validateSupport(_ data: Data) throws {
        guard data.count <= 56 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        let files = try JSONDecoder().decode([String: Data].self, from: data)
        var bytes = 0
        guard files.count <= 32 else { throw CocoaError(.fileWriteOutOfSpace) }
        for (path, body) in files {
            let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            guard path.hasPrefix("/support/"), path.utf8.count <= 256, !path.contains("\\"), !path.contains("\0"),
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  body.count <= supportLimit - bytes else { throw CocoaError(.fileReadCorruptFile) }
            bytes += body.count
        }
    }
    static let maximumFiles = 128
    static let maximumBytes = 512 * 1024

    static func contents(_ resources: [MacOSExtensionBuild.File]) throws -> [String: Data] {
        let assets = resources.filter { $0.path.hasPrefix("assets/") }
        guard assets.count <= maximumFiles else { throw MacOSExtensionBuild.Failure.limit }
        var result: [String: Data] = [:], bytes = 0
        for asset in assets {
            let components = asset.path.split(separator: "/", omittingEmptySubsequences: false)
            guard asset.path.utf8.count <= 1024, components.count > 1, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !asset.path.contains("\\"), !asset.path.contains("\0"),
                  asset.body.count <= maximumBytes - bytes,
                  result["/" + asset.path] == nil else { throw MacOSExtensionBuild.Failure.limit }
            result["/" + asset.path] = asset.body
            bytes += asset.body.count
        }
        return result
    }

    package static let files: [RaycastStoreBuildProject.File] = [
        .init(path: "node_modules/@keylane/reviewed-assets/index.js", body: Data(source.utf8)),
        .init(path: "node_modules/@keylane/reviewed-assets/promises.js", body: Data(
            #"export { readFile, writeFile } from "./index.js"; import { readFile, writeFile } from "./index.js"; export default Object.freeze({ readFile, writeFile });"#.utf8))
    ]

    private static let source = #"""
    import { __keylaneReadCacheIndex } from "@raycast/api";
    const readAsset = globalThis.keylane.readAsset;
    const readSupport = globalThis.keylane.readSupport;
    const writeSupport = globalThis.keylane.writeSupport;

    function assetError(code) {
      const error = new Error(code === "ENOENT" ? "Packaged asset not found" : "Packaged asset read denied");
      error.code = code;
      return error;
    }

    export function readFileSync(path, options) {
      const encoding = typeof options === "string" ? options : options?.encoding;
      if (options?.flag !== undefined && options.flag !== "r") throw assetError("EACCES");
      if (typeof path !== "string") throw assetError("EACCES");
      if (path.startsWith("/support/") && path.endsWith("/cache/entries.json")) {
        const index = __keylaneReadCacheIndex(path);
        if (index !== undefined) return encoding == null ? new TextEncoder().encode(index) : index;
      }
      const read = path.startsWith("/support/") ? readSupport : readAsset;
      if (typeof read !== "function") throw assetError("EACCES");
      if (encoding != null && encoding !== "utf8" && encoding !== "utf-8") {
        throw new TypeError("Only UTF-8 and binary asset reads are available");
      }
      const value = read(path, encoding != null);
      if (value == null) throw assetError("ENOENT");
      return encoding == null ? Uint8Array.from(value) : value;
    }

    export async function readFile(path, options) {
      return readFileSync(path, options);
    }

    export function writeFileSync(path, value, options) {
      if (typeof path !== "string" || !path.startsWith("/support/") || (path.endsWith("/cache/entries.json") && typeof globalThis.keylane.updateCache === "function") || typeof writeSupport !== "function") {
        throw assetError("EACCES");
      }
      const encoding = typeof options === "string" ? options : options?.encoding;
      if (options?.flag !== undefined && options.flag !== "w") throw assetError("EACCES");
      if (encoding != null && encoding !== "utf8" && encoding !== "utf-8") {
        throw new TypeError("Only UTF-8 and binary support writes are available");
      }
      const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
      if (!(bytes instanceof Uint8Array)) throw new TypeError("Expected text or bytes");
      if (bytes.length > 32768 || !writeSupport(path, Array.from(bytes))) throw assetError("EACCES");
    }

    export async function writeFile(path, value, options) {
      writeFileSync(path, value, options);
    }

    export const promises = Object.freeze({ readFile, writeFile });
    export default Object.freeze({ readFileSync, writeFileSync, promises });
    """#
}
