const assert = require("node:assert/strict");
const { test } = require("node:test");
const noView = require("./raycast-api.cjs");
const view = require("./view-api.cjs");

test("legacy storage aliases share the command's LocalStorage snapshot", async () => {
  const result = await view.runCommand(async () => {
    assert.deepEqual(await view.allLocalStorageItems(), { old: "value" });
    await view.setLocalStorageItem("count", 2);
    assert.equal(await view.LocalStorage.getItem("count"), 2);
    await view.removeLocalStorageItem("old");
    assert.equal(await view.getLocalStorageItem("old"), undefined);
    await view.clearLocalStorage();
    assert.deepEqual(await view.LocalStorage.allItems(), {});
    await view.setLocalStorageItem("active", true);
    await view.copyTextToClipboard("fixture");
  }, { storage: { old: "value" } });
  assert.equal(result.kind, "copy");
  assert.equal(result.text, "fixture");
  assert.deepEqual({ ...result.storage }, { active: true });
});

test("legacy storage and clipboard aliases preserve denied grants", async () => {
  await view.runCommand(async () => {
    await assert.rejects(view.getLocalStorageItem("old"), /LocalStorage unavailable/);
    await assert.rejects(view.clearLocalStorage(), /LocalStorage unavailable/);
    await assert.rejects(view.setLocalStorageItem("count", 2), /LocalStorage unavailable/);
    await assert.rejects(view.copyTextToClipboard("fixture"), /Clipboard action unavailable/);
    await assert.rejects(view.pasteText("fixture"), /Clipboard action unavailable/);
  }, {});
});

test("no-view clipboard aliases request the original broker capabilities", async (t) => {
  const request = t.mock.method(noView, "request", async () => "");
  await noView.copyTextToClipboard("copy fixture");
  await noView.pasteText("paste fixture");
  assert.deepEqual(request.mock.calls.map(({ arguments: args }) => args), [
    ["clipboard.copy", "copy fixture"],
    ["clipboard.paste", "paste fixture"],
  ]);
});
