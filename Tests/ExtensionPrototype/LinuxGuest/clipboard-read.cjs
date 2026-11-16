const maximumTextBytes = 2048;

function makeClipboardReaders(request, isAllowed) {
  async function read(options = {}) {
    if (!options || typeof options !== "object" || Array.isArray(options) ||
        (options.offset !== undefined && options.offset !== 0)) {
      throw new TypeError("Only the current clipboard is available");
    }
    if (!isAllowed()) throw new Error("Clipboard reading requires a selected view action with clipboard access");
    const result = JSON.parse(await request("clipboard.read", ""));
    if (!result || typeof result !== "object" || Array.isArray(result)) {
      throw new Error("Invalid clipboard result");
    }
    if (result.text === undefined) return {};
    if (typeof result.text !== "string" || Buffer.byteLength(result.text) > maximumTextBytes) {
      throw new Error("Invalid clipboard text");
    }
    return { text: result.text };
  }

  async function readText(options) {
    return (await read(options)).text;
  }

  return { read, readText };
}

module.exports = { makeClipboardReaders };
