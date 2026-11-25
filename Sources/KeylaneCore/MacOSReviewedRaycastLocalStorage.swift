import Foundation

/// LocalStorage is installation-scoped and independent of evictable Cache entries.
struct MacOSReviewedRaycastLocalStorage: Sendable {
    static let capability = "storage.request"
    static let maximumBytes = 32 * 1024

    let root: URL

    func read(for ticket: StoreGuestRunTicket) throws -> String {
        let path = file(installationID: ticket.installation.id)
        let descriptor = Darwin.open(path.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor == -1 && errno == ENOENT { return "[]" }
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_size <= Self.maximumBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        try Self.validate(data)
        return String(decoding: data, as: UTF8.self)
    }

    func write(_ data: Data, for ticket: StoreGuestRunTicket) throws {
        try Self.validate(data)
        try data.write(to: file(installationID: ticket.installation.id), options: .atomic)
    }

    static func validate(_ data: Data) throws {
        guard data.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let entries = try JSONDecoder().decode([[String]].self, from: data)
        var keys = Set<String>()
        for entry in entries {
            guard entry.count == 2, isUTF16Hex(entry[0]), keys.insert(entry[0]).inserted,
                  isValue(entry[1]) else { throw CocoaError(.fileReadCorruptFile) }
        }
    }

    private static func isUTF16Hex(_ string: some StringProtocol, length: Int? = nil) -> Bool {
        let bytes = string.utf8
        return (length.map { $0 == bytes.count } ?? (bytes.count.isMultiple(of: 4))) &&
            bytes.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isValue(_ value: String) -> Bool {
        switch value.first {
        case "s": isUTF16Hex(value.dropFirst())
        case "n": isUTF16Hex(value.dropFirst(), length: 16)
        case "b": value == "b0" || value == "b1"
        default: false
        }
    }

    func remove(installationID: UUID) {
        _ = Darwin.unlink(file(installationID: installationID.uuidString).path)
    }

    private func file(installationID: String) -> URL {
        let digest = MacOSExtensionBuild.hash(Data(installationID.utf8))
        return root.appendingPathComponent("local-storage-\(digest).json")
    }

    static let source = #"""
    const nativeStorageRead = globalThis.keylane.localStorageSnapshot;
    const nativeStorageWrite = globalThis.keylane.updateLocalStorage;
    let localStorageEntries;

    function localStorageState() {
      if (typeof nativeStorageRead !== "string" || typeof nativeStorageWrite !== "function") {
        throw new Error("LocalStorage is unavailable for this extension invocation");
      }
      return localStorageEntries ??= new Map(JSON.parse(nativeStorageRead));
    }

    function localStorageKey(key) {
      if (typeof key !== "string") throw new TypeError("Invalid LocalStorage key");
      return Array.from({ length: key.length }, (_, index) =>
        key.charCodeAt(index).toString(16).padStart(4, "0")).join("");
    }

    function localStorageString(encoded) {
      let decoded = "";
      for (let index = 0; index < encoded.length; index += 4) {
        decoded += String.fromCharCode(parseInt(encoded.slice(index, index + 4), 16));
      }
      return decoded;
    }

    function localStorageValue(value) {
      if (typeof value === "string") return "s" + localStorageKey(value);
      if (typeof value === "boolean") return value ? "b1" : "b0";
      if (typeof value === "number") {
        const bytes = new DataView(new ArrayBuffer(8));
        bytes.setFloat64(0, value);
        return "n" + bytes.getUint32(0).toString(16).padStart(8, "0")
          + bytes.getUint32(4).toString(16).padStart(8, "0");
      }
      throw new TypeError("Invalid LocalStorage item");
    }

    function localStorageDecode(value) {
      if (value === undefined) return undefined;
      if (value[0] === "s") return localStorageString(value.slice(1));
      if (value[0] === "b") return value === "b1";
      const bytes = new DataView(new ArrayBuffer(8));
      bytes.setUint32(0, parseInt(value.slice(1, 9), 16));
      bytes.setUint32(4, parseInt(value.slice(9), 16));
      return bytes.getFloat64(0);
    }

    function saveLocalStorage(entries) {
      if (!nativeStorageWrite(JSON.stringify([...entries]))) {
        throw new RangeError("LocalStorage exceeds the reviewed size limit");
      }
      localStorageEntries = entries;
    }

    export const LocalStorage = Object.freeze({
      async getItem(key) {
        return localStorageDecode(localStorageState().get(localStorageKey(key)));
      },
      async setItem(key, value) {
        const entries = new Map(localStorageState());
        entries.set(localStorageKey(key), localStorageValue(value));
        saveLocalStorage(entries);
      },
      async removeItem(key) {
        const entries = new Map(localStorageState());
        if (entries.delete(localStorageKey(key))) saveLocalStorage(entries);
      },
      async allItems() {
        return Object.fromEntries([...localStorageState()].map(([key, value]) =>
          [localStorageString(key), localStorageDecode(value)]));
      },
      async clear() {
        if (localStorageState().size > 0) saveLocalStorage(new Map());
      },
    });

    export const getLocalStorageItem = LocalStorage.getItem;
    export const setLocalStorageItem = LocalStorage.setItem;
    export const removeLocalStorageItem = LocalStorage.removeItem;
    export const allLocalStorageItems = LocalStorage.allItems;
    export const clearLocalStorage = LocalStorage.clear;
    """#
}
