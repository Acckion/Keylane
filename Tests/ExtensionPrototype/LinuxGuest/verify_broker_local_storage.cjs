const assert = require("node:assert/strict");
const test = require("node:test");
const { makeBrokerLocalStorage } = require("./broker-local-storage.cjs");

test("LocalStorage broker preserves values and exact JavaScript string keys", async () => {
  let entries = Object.create(null);
  const storage = makeBrokerLocalStorage(async (capability, text) => {
    assert.equal(capability, "storage.request");
    const { operation, key, value } = JSON.parse(text);
    if (key !== undefined) assert.match(key, /^(?:[a-f0-9]{4})*$/);
    switch (operation) {
      case "get": return JSON.stringify({ value: entries[key] });
      case "set": entries[key] = value; break;
      case "remove": delete entries[key]; break;
      case "all": return JSON.stringify(entries);
      case "clear": entries = Object.create(null); break;
      default: assert.fail("unexpected operation");
    }
    return "";
  });

  await storage.setItem("é", false);
  await storage.setItem("e\u0301", 0);
  await storage.setItem("__proto__", "");
  await storage.setItem("", "empty key");
  assert.equal(await storage.getItem("é"), false);
  assert.equal(await storage.getItem("e\u0301"), 0);
  assert.equal(await storage.getItem("missing"), undefined);
  assert.equal(await storage.getItem("x".repeat(3000)), undefined);
  await assert.rejects(storage.setItem("bad", Infinity), /Invalid LocalStorage item/);
  await assert.rejects(storage.setItem("bad", null), /Invalid LocalStorage item/);
  assert.deepEqual(await storage.allItems(), Object.fromEntries([
    ["é", false], ["e\u0301", 0], ["__proto__", ""], ["", "empty key"],
  ]));
  await storage.removeItem("é");
  assert.equal(await storage.getItem("é"), undefined);
  await storage.clear();
  assert.deepEqual(await storage.allItems(), {});
});
