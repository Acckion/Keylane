const assert = require("node:assert/strict");
const { test } = require("node:test");
const { openWithComponent, openWithEffect, makeClearClipboard } = require("./open-with-clipboard.cjs");

test("Open With describes the chooser action and sends one validated file path", () => {
  const OpenWith = openWithComponent((type) => (props) => ({ type, props }));
  const path = "/private/tmp/示例 文件.txt";
  const action = OpenWith({ path });
  assert.deepEqual(action, { type: "openWith", props: { title: "Open With", path, icon: "upload-16" } });
  assert.equal(OpenWith({ title: "Choose Editor", path }).props.title, "Choose Editor");
  assert.deepEqual(openWithEffect(action.props.path), { kind: "openWithFile", paths: [path] });
  assert.deepEqual(openWithEffect(new URL("file:///private/tmp/A%20B")), {
    kind: "openWithFile", paths: ["/private/tmp/A B"],
  });
  assert.deepEqual(openWithEffect("file:///private/tmp/A%20B"), {
    kind: "openWithFile", paths: ["/private/tmp/A B"],
  });
});

test("Open With describes validated web targets and rejects relative and unsafe targets", () => {
  assert.deepEqual(openWithEffect("https://example.invalid/文档"), {
    kind: "openWithURL", text: "https://example.invalid/%E6%96%87%E6%A1%A3",
  });
  for (const path of ["./relative.txt", "https://user@example.invalid/file", "https://example.invalid/%0a",
    "javascript:alert(1)", "/private/tmp/control\x00.txt",
    "//remote/file", "/private/tmp/" + "字".repeat(700)]) {
    assert.throws(() => openWithEffect(path));
  }
});

test("Clipboard clear proposes an empty effect through the selected action gate", async () => {
  let active = false;
  const effects = [];
  const clear = makeClearClipboard((effect) => {
    if (!active || effects.length) throw new Error("Requires a selected view action");
    effects.push(effect);
  });
  await assert.rejects(clear(), /Requires a selected view action/);
  assert.deepEqual(effects, []);
  active = true;
  assert.equal(await clear(), undefined);
  assert.deepEqual(effects, [{ kind: "clearClipboard" }]);
  await assert.rejects(clear(), /Requires a selected view action/);
});

test("reviewed view selects OpenWithAction and both clipboard clear entry points", async () => {
  const { Action, ActionPanel, Clipboard, Detail, OpenWithAction, clearClipboard, render, runCommand, useEffect } = require("./view-api.cjs");
  assert.equal(Clipboard.clear, clearClipboard);
  const path = "/private/tmp/选择.txt";
  const command = () => Detail({ actions: ActionPanel({ children: [
    OpenWithAction({ path }),
    Action({ title: "Clear", onAction: () => Clipboard.clear() }),
    Action({ title: "Clear (legacy)", onAction: clearClipboard }),
  ] }) });
  const snapshot = await render(command, {});
  assert.deepEqual(snapshot.detail.actions.map(({ kind }) => kind), ["openWith", "callback", "callback"]);

  const select = (id) => render(command, { action: { row: 0, id } });
  assert.deepEqual(await select(0), { kind: "openWithFile", paths: [path] });
  assert.deepEqual(await select(1), { kind: "clearClipboard" });
  assert.deepEqual(await select(2), { kind: "clearClipboard" });

  await assert.rejects(render(() => {
    useEffect(() => Clipboard.clear());
    return Detail({});
  }, {}), /require[s]? a selected view action/);
  await assert.rejects(runCommand(clearClipboard, {}), /require[s]? a selected view action/);
});
