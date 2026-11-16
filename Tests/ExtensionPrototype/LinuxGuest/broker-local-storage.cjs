function encodeKey(key) {
  if (typeof key !== "string") throw new TypeError("Invalid LocalStorage key");
  // An ASCII key preserves exact JavaScript code units across the host's JSON and Swift dictionaries.
  return Buffer.from(key, "utf16le").toString("hex");
}

function makeBrokerLocalStorage(request) {
  async function send(operation, fields = {}) {
    return request("storage.request", JSON.stringify({ operation, ...fields }));
  }

  return {
    async getItem(key) {
      const encoded = encodeKey(key);
      if (encoded.length > 4096) return undefined;
      return JSON.parse(await send("get", { key: encoded })).value;
    },
    async setItem(key, value) {
      if (typeof value !== "string" && typeof value !== "boolean" && !Number.isFinite(value)) {
        throw new TypeError("Invalid LocalStorage item");
      }
      await send("set", { key: encodeKey(key), value });
    },
    async removeItem(key) {
      const encoded = encodeKey(key);
      if (encoded.length <= 4096) await send("remove", { key: encoded });
    },
    async allItems() {
      const values = JSON.parse(await send("all"));
      return Object.fromEntries(Object.entries(values).map(([key, value]) => [Buffer.from(key, "hex").toString("utf16le"), value]));
    },
    async clear() {
      await send("clear");
    },
  };
}

module.exports = { makeBrokerLocalStorage };
