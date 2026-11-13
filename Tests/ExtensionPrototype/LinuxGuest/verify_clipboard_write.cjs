const assert = require("node:assert/strict");
const test = require("node:test");
const { Action, ActionPanel, Clipboard, Detail, render } = require("./view-api.cjs");

const action = { row: 0, id: 0 };
const command = (item) => () => Detail({ actions: ActionPanel({ children: item }) });

test("copy completion invokes onCopy only for the same confirmed payload", async () => {
  const calls = [];
  const content = { html: "<strong>中文</strong>", text: "中文" };
  const view = command(Action.CopyToClipboard({
    content, concealed: true,
    onCopy: (value) => { calls.push(value); },
  }));
  const result = await render(view, { action });
  assert.deepEqual(result.clipboardContent, content);
  assert.equal(result.concealed, true);
  assert.match(result.copyReceipt, /^[0-9a-f]{64}$/);
  assert.equal(calls.length, 0);
  await assert.rejects(render(view, { action, copyReceipt: "f".repeat(64) }), /Invalid clipboard completion receipt/);
  const changed = command(Action.CopyToClipboard({ content: "changed", onCopy: () => assert.fail("stale receipt") }));
  await assert.rejects(render(changed, { action, copyReceipt: result.copyReceipt }), /Invalid clipboard completion receipt/);
  const retitled = command(Action.CopyToClipboard({ title: "Different action", content, concealed: true,
    onCopy: () => assert.fail("unrelated copy callback") }));
  await assert.rejects(render(retitled, { action, copyReceipt: result.copyReceipt }), /Invalid clipboard completion receipt/);
  const unrelated = command(Action({ title: "Unrelated", onAction: () => assert.fail("unexpected callback") }));
  await assert.rejects(render(unrelated, { action, copyReceipt: result.copyReceipt }), /Invalid clipboard completion receipt/);
  assert.deepEqual(await render(view, { action, copyReceipt: result.copyReceipt }), { kind: "action" });
  assert.deepEqual(calls, [content]);
});

test("CopyToClipboard uses SDK defaults and honours the deprecated transient flag", async () => {
  const { CopyToClipboardAction, Icon } = require("./view-api.cjs");
  assert.equal(CopyToClipboardAction, Action.CopyToClipboard);
  assert.equal(ActionPanel.Item.CopyToClipboard, Action.CopyToClipboard);
  const calls = [];
  const commandFor = (content, options) => command(CopyToClipboardAction({
    content, ...options, onCopy: (value) => calls.push(value),
  }));
  const view = commandFor(42, { transient: true });
  const [{ title, icon }] = (await render(view, {})).detail.actions;
  assert.equal(title, "Copy to Clipboard");
  assert.equal(icon, Icon.Clipboard);
  const result = await render(view, { action });
  assert.deepEqual(result.clipboardContent, { text: "42" });
  assert.equal(result.concealed, true);
  await assert.rejects(render(commandFor("42", { transient: true }), { action, copyReceipt: result.copyReceipt }),
    /Invalid clipboard completion receipt/);
  await render(view, { action, copyReceipt: result.copyReceipt });
  assert.deepEqual(calls, [42]);
  assert.equal((await render(commandFor("public", { transient: true, concealed: false }), { action })).concealed, undefined);
});

test("selected callbacks can propose richer copy and paste while render and search cannot", async () => {
  const copy = command(Action({ title: "Copy", onAction: () => Clipboard.copy(42, { concealed: true }) }));
  assert.deepEqual(await render(copy, { action }), {
    kind: "copy", clipboardContent: { text: "42" }, concealed: true,
  });
  const paste = command(Action({ title: "Paste", onAction: () => Clipboard.paste({ file: Buffer.from("/tmp/example") }, { closeMainWindow: false }) }));
  assert.deepEqual(await render(paste, { action }), {
    kind: "paste", clipboardContent: { file: "/tmp/example" }, keepOpen: true,
  });
  await assert.rejects(Clipboard.copy("outside action"), /Clipboard action unavailable/);
  const restricted = () => Detail({ actions: ActionPanel({ children: ActionPanel.Submenu({
    title: "Restricted", onOpen: () => Clipboard.copy({ text: "private" }),
  }) }) });
  await assert.rejects(render(restricted, { actionMenuRow: 0, actionMenuRoute: [{ index: 0 }] }), /Clipboard action unavailable/);
});
