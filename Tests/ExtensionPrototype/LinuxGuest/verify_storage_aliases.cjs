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

test("no-view clipboard copies share the typed representations and concealment options", async (t) => {
  const request = t.mock.method(noView, "request", async () => "");
  await noView.Clipboard.copy({ html: "<b>fixture</b>", text: "fixture" }, { transient: true });
  await noView.Clipboard.copy({ file: new URL("file:///tmp/keylane%20fixture.txt") });
  await noView.copyTextToClipboard(42, { concealed: false, transient: true });
  assert.deepEqual(request.mock.calls.map(({ arguments: [capability, payload] }) =>
    [capability, JSON.parse(payload)]), [
    ["clipboard.write", { content: { html: "<b>fixture</b>", text: "fixture" }, concealed: true }],
    ["clipboard.write", { content: { file: "/tmp/keylane fixture.txt" }, concealed: false }],
    ["clipboard.write", { content: { text: "42" }, concealed: false }],
  ]);
});

test("signed copy waits for a typed native clipboard write", async (t) => {
  const broker = require("./raycast-api.cjs");
  const api = require("./view-api.cjs");
  let acknowledge;
  const receipt = new Promise((resolve) => { acknowledge = resolve; });
  let continued = false;
  const calls = [];
  const bridge = t.mock.method(broker, "request", async (capability, text) => {
    calls.push([capability, JSON.parse(text)]);
    await receipt;
  });
  const command = () => api.Detail({ actions: api.ActionPanel({ children: api.Action({
    title: "Copy", async onAction() {
      await api.Clipboard.copy({ html: "<b>fixture</b>", text: "fixture" }, { transient: true });
      continued = true;
    },
  }) }) });
  const selection = { action: { row: 0, id: 0 }, finderRevealAllowed: true, liveToast: true };
  const pending = api.render(command, selection);
  await new Promise(setImmediate);
  assert.equal(continued, false);
  assert.deepEqual(calls, [["clipboard.write", { content: { html: "<b>fixture</b>", text: "fixture" }, concealed: true }]]);
  acknowledge();
  assert.deepEqual(await pending, { kind: "action" });
  assert.equal(continued, true);

  const menu = () => api.MenuBarExtra({ children: api.MenuBarExtra.Item({
    title: "Copy", onAction: () => api.copyTextToClipboard(123),
  }) });
  const menuInput = { menuAction: 0, wallTime: 1, finderRevealAllowed: true };
  assert.deepEqual(await api.runMenuBar(menu, menuInput), { kind: "menuAction" });
  assert.deepEqual(calls.at(-1), ["clipboard.write", { content: { text: "123" }, concealed: false }]);
  bridge.mock.mockImplementation(async () => { throw new Error("Host action failed"); });
  await assert.rejects(api.runMenuBar(menu, menuInput), /Host action failed/);
});
