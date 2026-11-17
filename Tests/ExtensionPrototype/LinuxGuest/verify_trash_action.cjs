const assert = require("node:assert/strict");
const { test } = require("node:test");
const { trashComponent, trashEffect, makeTrash } = require("./trash-action.cjs");

test("Trash action describes a destructive proposal without moving files", () => {
  const Trash = trashComponent((type) => (props) => ({ type, props }));
  const paths = ["/tmp/中文.txt"];
  const expected = { type: "trashFiles", props: { paths, title: "Move to Trash", icon: "trash-16", style: "destructive" } };
  assert.deepEqual(Trash({ paths }), expected);
  assert.deepEqual(Trash({ paths, title: "Clean up", style: "regular" }), {
    ...expected,
    props: { ...expected.props, title: "Clean up" },
  });
});

test("Trash requests support single and multiple PathLike inputs with stable deduplication", async () => {
  assert.deepEqual(trashEffect(new URL("file:///tmp/some%20file")), {
    kind: "trashFiles", paths: ["/tmp/some file"],
  });

  const calls = [];
  const trash = makeTrash((effect) => calls.push(effect));
  await trash(["/tmp/中文.txt", Buffer.from("/tmp/other"), "/tmp/中文.txt"]);
  assert.deepEqual(calls, [{ kind: "trashFiles", paths: ["/tmp/中文.txt", "/tmp/other"] }]);
});

test("Trash rejects invalid targets and preserves selected-action errors", async () => {
  const trash = makeTrash(() => assert.fail("invalid target emitted a request"));
  await trash([]);
  assert.throws(() => trashEffect(Array.from({ length: 9 }, (_, index) => `/tmp/${index}`)), RangeError);
  for (const path of ["/", "", new URL("https://example.com/path"), "/tmp/line\nbreak"]) {
    await assert.rejects(trash(path), TypeError);
  }
  const longPaths = ["a", "b", "c"].map((prefix) => `/${prefix.repeat(1500)}`);
  assert.throws(() => trashEffect(longPaths), TypeError);
  await assert.rejects(trash(["/tmp/folder", "/tmp/folder/file"]), /paths overlap/);
  const unavailable = makeTrash(() => { throw new Error("Requires a selected action"); });
  await assert.rejects(unavailable("/tmp/synthetic"), /selected action/);
});

test("selected view trash waits for all items and rejects cancellation or failure", async (t) => {
  const broker = require("./raycast-api.cjs");
  const { Action, ActionPanel, Detail, render, trash } = require("./view-api.cjs");
  let reply;
  const ack = new Promise((resolve) => { reply = resolve; });
  const bridge = t.mock.method(broker, "request", (capability, input) => {
    assert.equal(capability, "files.trash");
    assert.deepEqual(JSON.parse(input), ["/tmp/a", "/tmp/b"]);
    return ack;
  });
  let continued = false;
  const command = () => Detail({ actions: ActionPanel({ children: Action({ title: "Trash", async onAction() {
    await trash(["/tmp/a", Buffer.from("/tmp/b")]);
    continued = true;
  } }) }) });
  const selection = { action: { row: 0, id: 0 }, finderRevealAllowed: true };
  await assert.rejects(render(command, selection), /authorized view action/);
  assert.equal(bridge.mock.callCount(), 0);
  const authorized = { ...selection, liveToast: true };
  const pending = render(command, authorized);
  await new Promise(setImmediate);
  assert.equal(bridge.mock.callCount(), 1);
  assert.equal(continued, false);
  reply("moved");
  assert.deepEqual(await pending, { kind: "action" });
  assert.equal(continued, true);

  continued = false;
  bridge.mock.mockImplementation(async () => "cancelled");
  await assert.rejects(render(command, authorized), /was cancelled/);
  bridge.mock.mockImplementation(async () => "failed");
  await assert.rejects(render(command, authorized), /Unable to move all files/);
  assert.equal(continued, false);
});

test("Trash accepts relative, home-alias, and file URL paths with the same receipt across modes", async (t) => {
  const { resolve } = require("node:path");
  const { MenuBarExtra, runCommand, runMenuBar, showHUD, trash } = require("./view-api.cjs");
  const broker = require("./raycast-api.cjs");
  const calls = [];
  t.mock.method(broker, "request", async (capability, payload) => {
    calls.push([capability, JSON.parse(payload)]);
    return "moved";
  });
  await broker.trash(Buffer.from("./target"));
  const menu = () => MenuBarExtra({ children: MenuBarExtra.Item({
    title: "Test", onAction: () => trash("/keylane-host-home/Documents/target"),
  }) });
  await assert.rejects(runMenuBar(menu, { wallTime: 1, menuAction: 0 }), /authorized view action/);
  assert.deepEqual(await runMenuBar(menu, { wallTime: 1, menuAction: 0, finderRevealAllowed: true }), { kind: "menuAction" });
  await runCommand(async () => {
    await trash(new URL("file:///private/tmp/test"));
    await showHUD("done");
  }, { mode: "generateV5", suitePreferencesAllowed: true, finderRevealAllowed: true });
  assert.deepEqual(calls, [
    ["files.trash", [resolve("target")]],
    ["files.trash", ["/keylane-host-home/Documents/target"]],
    ["files.trash", ["/private/tmp/test"]],
    ["feedback.hud", { text: "done", clearRootSearch: false, popToRootType: "default" }],
  ]);
});

test("imperative Trash sends bounded batches in order and stops as soon as one fails", async () => {
  const paths = Array.from({ length: 17 }, (_, index) => "/tmp/fixture-" + index);
  const calls = [];
  const success = makeTrash(({ paths }) => { calls.push(paths); });
  await success([...paths, paths[0]]);
  assert.deepEqual(calls, [paths.slice(0, 8), paths.slice(8, 16), paths.slice(16)]);

  calls.length = 0;
  const cancelled = makeTrash(async ({ paths }) => {
    calls.push(paths);
    if (calls.length === 2) throw new Error("cancelled");
  });
  await assert.rejects(cancelled(paths), /cancelled/);
  assert.deepEqual(calls, [paths.slice(0, 8), paths.slice(8, 16)]);

  calls.length = 0;
  const long = ["a", "b", "c"].map((prefix) => `/${prefix.repeat(1500)}`);
  await success(long);
  assert.deepEqual(calls, [long.slice(0, 2), long.slice(2)]);
  calls.length = 0;
  await assert.rejects(success([...paths, "/"]), TypeError);
  assert.deepEqual(calls, []);
});
