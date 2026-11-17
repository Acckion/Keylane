const assert = require("node:assert/strict");
const test = require("node:test");
const { makeBrokerLocalStorage } = require("./broker-local-storage.cjs");

test("LocalStorage broker preserves values and exact JavaScript string keys", async () => {
  let entries = Object.create(null);
  let snapshot;
  const offsets = [];
  const storage = makeBrokerLocalStorage(async (capability, text) => {
    assert.equal(capability, "storage.request");
    const { operation, key, value, offset } = JSON.parse(text);
    if (key !== undefined) assert.match(key, /^(?:[a-f0-9]{4})*$/);
    switch (operation) {
      case "get": return JSON.stringify({ value: entries[key] });
      case "set": entries[key] = value; break;
      case "remove": delete entries[key]; break;
      case "all": {
        offsets.push(offset);
        if (offset === 0) snapshot = Buffer.from(JSON.stringify(entries));
        const end = Math.min(offset + 8192, snapshot.length);
        return JSON.stringify({ chunk: snapshot.subarray(offset, end).toString("base64"),
          nextOffset: end < snapshot.length ? end : 0 });
      }
      case "clear": entries = Object.create(null); break;
      default: assert.fail("unexpected operation");
    }
    return "";
  });

  await storage.setItem("é", false);
  await storage.setItem("e\u0301", 0);
  await storage.setItem("signed zero", -0);
  await storage.setItem("__proto__", "");
  await storage.setItem("", "empty key");
  const exactValue = "A\ud800中文\udfff🚀";
  await storage.setItem("utf16", exactValue);
  assert.deepEqual(entries[Buffer.from("utf16", "utf16le").toString("hex")], {
    utf16: Buffer.from(exactValue, "utf16le").toString("base64"),
  });
  assert.equal(await storage.getItem("utf16"), exactValue);
  assert.equal(await storage.getItem("é"), false);
  assert.equal(await storage.getItem("e\u0301"), 0);
  assert.equal(await storage.getItem("signed zero"), -0);
  assert.equal(await storage.getItem("missing"), undefined);
  assert.equal(await storage.getItem("x".repeat(25000)), undefined);
  const numericValues = Object.entries({
    nan: NaN, infinity: Infinity, negativeInfinity: -Infinity, min: Number.MIN_VALUE, max: Number.MAX_VALUE,
  });
  for (const [key, value] of numericValues) {
    await storage.setItem(key, value);
    assert.equal(await storage.getItem(key), value);
  }
  entries[Buffer.from("legacy", "utf16le").toString("hex")] = { number: "-0" };
  assert.equal(await storage.getItem("legacy"), -0);
  await assert.rejects(storage.setItem("bad", null), /Invalid LocalStorage item/);
  assert.deepEqual(await storage.allItems(), Object.fromEntries([
    ["é", false], ["e\u0301", 0], ["__proto__", ""], ["", "empty key"], ["utf16", exactValue], ["signed zero", -0], ["legacy", -0], ...numericValues,
  ]));
  await storage.removeItem("é");
  assert.equal(await storage.getItem("é"), undefined);
  const large = "中文🚀".repeat(400);
  for (const key of ["one", "two", "three"]) await storage.setItem(key, large);
  offsets.length = 0;
  const [first, second] = await Promise.all([storage.allItems(), storage.allItems()]);
  assert.deepEqual(offsets, [0, 8192, 0, 8192]);
  assert.equal(first.three, large);
  assert.deepEqual(first, second);
  await storage.clear();
  assert.deepEqual(await storage.allItems(), {});
});

test("LocalStorage rejects invalid continuation offsets and retries from the beginning", async () => {
  const offsets = [];
  const storage = makeBrokerLocalStorage(async (_capability, text) => {
    const { offset } = JSON.parse(text);
    offsets.push(offset);
    if (offsets.length === 1) {
      return JSON.stringify({ chunk: Buffer.alloc(8192).toString("base64"), nextOffset: 16384 });
    }
    return JSON.stringify({ chunk: Buffer.from("{}").toString("base64"), nextOffset: 0 });
  });
  await assert.rejects(storage.allItems(), /Invalid LocalStorage snapshot page/);
  assert.deepEqual(await storage.allItems(), {});
  assert.deepEqual(offsets, [0, 0]);
});

test("large local storage values commit only after upload and page through a separate snapshot", async () => {
  const calls = [];
  let staging = Buffer.alloc(0);
  let stored;
  let snapshot;
  let failUpload = true;
  const key = "𠮷".repeat(1100);
  const value = "中文🚀".repeat(1500) + "\ud800";
  const storage = makeBrokerLocalStorage(async (_capability, text) => {
    const request = JSON.parse(text);
    calls.push(request.operation);
    switch (request.operation) {
      case "upload":
        if (request.offset === 0) staging = Buffer.alloc(0);
        assert.equal(request.offset, staging.length);
        if (failUpload && request.offset > 0) throw new Error("Interrupted upload");
        staging = Buffer.concat([staging, Buffer.from(request.chunk, "base64")]);
        return "";
      case "commit": {
        assert.equal(request.size, staging.length);
        const entry = JSON.parse(staging.toString());
        assert.equal(Buffer.from(entry.key, "hex").toString("utf16le"), key);
        if (entry.operation === "set") {
          stored = entry.value;
          return "";
        }
        assert.equal(entry.operation, "get");
        snapshot = Buffer.from(JSON.stringify({ value: stored }));
        return page(0);
      }
      case "getPage": return page(request.offset);
      default: assert.fail("unexpected operation");
    }
  });
  function page(offset) {
    const end = Math.min(offset + 8192, snapshot.length);
    return JSON.stringify({ chunk: snapshot.subarray(offset, end).toString("base64"),
      nextOffset: end < snapshot.length ? end : 0 });
  }
  // An unpaired surrogate switches to base64-encoded UTF-16 and has a larger wire footprint.
  const supportedValue = value.slice(-4000);
  await assert.rejects(storage.setItem(key, supportedValue), /Interrupted upload/);
  assert.equal(stored, undefined);
  assert.ok(!calls.includes("commit"));
  failUpload = false;
  const [_, restored] = await Promise.all([storage.setItem(key, supportedValue), storage.getItem(key)]);
  assert.equal(restored, supportedValue);
  assert.ok(calls.includes("getPage"));
  assert.equal(calls.filter((operation) => operation === "commit").length, 2);
});
