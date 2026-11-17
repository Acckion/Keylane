const maximumBytes = Object.freeze({ text: 32 * 1024, html: 32 * 1024, file: 2048 });
const maximumPayloadBytes = 64 * 1024;
const chunkBytes = 11 * 1024;

function makeClipboardReaders(request, isAllowed) {
  async function readPayload(selector) {
    const first = JSON.parse(await request("clipboard.read", selector));
    if (first?.transfer === undefined) return first;
    const { transfer, bytes } = first;
    if (typeof transfer !== "string" || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(transfer) ||
        !Number.isSafeInteger(bytes) || bytes <= 4096 || bytes > maximumPayloadBytes) {
      throw new Error("Invalid clipboard transfer");
    }
    const snapshot = Buffer.alloc(bytes);
    for (let offset = 0; offset < bytes; offset += chunkBytes) {
      if (!isAllowed()) throw new Error("Clipboard read authorization expired");
      const encoded = await request("clipboard.readChunk", `${transfer}:${offset}`);
      const chunk = Buffer.from(encoded, "base64");
      if (chunk.length !== Math.min(chunkBytes, bytes - offset) || chunk.toString("base64") !== encoded) {
        throw new Error("Invalid clipboard transfer chunk");
      }
      chunk.copy(snapshot, offset);
    }
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(snapshot));
  }

  async function readFields(options, rich) {
    if (!options || typeof options !== "object" || Array.isArray(options)) {
      throw new TypeError("Invalid clipboard read options");
    }
    const offset = options.offset === undefined ? 0 : options.offset;
    if (!Number.isInteger(offset) || offset < 0 || offset > 5) {
      throw new TypeError("Clipboard history offset must be an integer from 0 to 5");
    }
    if (!isAllowed()) throw new Error("Clipboard reading requires a selected view action, menu item, or user-initiated command with clipboard access");
    const selector = offset === 0 ? (rich ? "content" : "") : `${rich ? "content" : "text"}:${offset}`;
    const result = await readPayload(selector);
    if (!result || typeof result !== "object" || Array.isArray(result)) {
      throw new Error("Invalid clipboard result");
    }
    const fields = {};
    for (const key of rich ? ["text", "html", "file"] : ["text"]) {
      if (result[key] === undefined) continue;
      if (typeof result[key] !== "string" || Buffer.byteLength(result[key]) > maximumBytes[key]) {
        throw new Error(`Invalid clipboard ${key}`);
      }
      fields[key] = result[key];
    }
    return fields;
  }

  async function read(options = {}) {
    return readFields(options, true);
  }

  async function readText(options = {}) {
    return (await readFields(options, false)).text;
  }

  return { read, readText };
}

module.exports = { makeClipboardReaders };
