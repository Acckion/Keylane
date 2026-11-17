function encodeKey(key) {
  if (typeof key !== "string") throw new TypeError("Invalid LocalStorage key");
  // An ASCII key preserves exact JavaScript code units across the host's JSON and Swift dictionaries.
  return Buffer.from(key, "utf16le").toString("hex");
}

function decodeValue(value) {
  if (value?.number === "-0") return -0;
  if (typeof value?.numberBits === "string") {
    return Buffer.from(value.numberBits, "hex").readDoubleBE();
  }
  if (value !== null && typeof value === "object" && typeof value.utf16 === "string") {
    return Buffer.from(value.utf16, "base64").toString("utf16le");
  }
  return value;
}

const storageCapacity = 96 * 1024;
const uploadChunkSize = 8192;
const pageSize = 8192;

function makeBrokerLocalStorage(request) {
  function send(operation, fields = {}) {
    return request("storage.request", JSON.stringify({ operation, ...fields }));
  }

  let pending = Promise.resolve();
  function ordered(run) {
    const result = pending.then(run);
    pending = result.catch(() => {});
    return result;
  }

  async function sendEntry(operation, fields) {
    const payload = Buffer.from(JSON.stringify({ operation, ...fields }));
    if (payload.length <= pageSize) return request("storage.request", payload.toString());
    if (payload.length > storageCapacity + 256) throw new RangeError("LocalStorage item exceeds capacity");
    for (let offset = 0; offset < payload.length; offset += uploadChunkSize) {
      const chunk = payload.subarray(offset, offset + uploadChunkSize);
      await send("upload", { offset, chunk: chunk.toString("base64") });
    }
    return send("commit", { size: payload.length });
  }

  async function readPages(firstPage, operation) {
    const chunks = [];
    let page = firstPage;
    let offset = 0;
    for (;;) {
      const chunk = Buffer.from(page.chunk, "base64");
      const end = offset + chunk.length;
      if (!chunk.length || chunk.length > pageSize || end > storageCapacity ||
          chunk.toString("base64") !== page.chunk ||
          (page.nextOffset !== 0 && (page.nextOffset !== end || chunk.length !== pageSize || end >= storageCapacity))) {
        throw new Error("Invalid LocalStorage snapshot page");
      }
      chunks.push(chunk);
      if (page.nextOffset === 0) return JSON.parse(Buffer.concat(chunks).toString("utf8"));
      offset = page.nextOffset;
      page = JSON.parse(await send(operation, { offset }));
    }
  }

  return {
    getItem(key) {
      return ordered(async () => {
        const encoded = encodeKey(key);
        if (encoded.length >= storageCapacity) return undefined;
        const first = JSON.parse(await sendEntry("get", { key: encoded }));
        const result = first.chunk === undefined ? first : await readPages(first, "getPage");
        return decodeValue(result.value);
      });
    },
    setItem(key, value) {
      return ordered(async () => {
        if (typeof value !== "string" && typeof value !== "boolean" && typeof value !== "number") {
          throw new TypeError("Invalid LocalStorage item");
        }
        // JSON consumers on the host reject unpaired surrogate escapes, which JavaScript strings permit.
        let wireValue = value;
        if (typeof value === "string" && !value.isWellFormed()) {
          wireValue = { utf16: Buffer.from(value, "utf16le").toString("base64") };
        } else if (typeof value === "number") {
          const bytes = Buffer.alloc(8);
          bytes.writeDoubleBE(value);
          wireValue = { numberBits: bytes.toString("hex") };
        }
        await sendEntry("set", { key: encodeKey(key), value: wireValue });
      });
    },
    removeItem(key) {
      return ordered(async () => {
        const encoded = encodeKey(key);
        if (encoded.length < storageCapacity) await sendEntry("remove", { key: encoded });
      });
    },
    allItems() {
      return ordered(async () => {
        const values = await readPages(JSON.parse(await send("all", { offset: 0 })), "all");
        return Object.fromEntries(Object.entries(values).map(([key, value]) => [
          Buffer.from(key, "hex").toString("utf16le"), decodeValue(value),
        ]));
      });
    },
    clear() {
      return ordered(async () => { await send("clear"); });
    },
  };
}

module.exports = { makeBrokerLocalStorage };
