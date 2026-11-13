const assert = require("node:assert/strict");
const test = require("node:test");
const { Action, ActionPanel, Detail, Grid, List, PasteAction, render } = require("./view-api.cjs");

test("standalone Detail exposes safe metadata links and renders invalid targets as labels", async () => {
  const { Metadata } = Detail;
  const reply = await render(() => Detail({ markdown: "Links", metadata: Metadata({ children: [
    Metadata.Link({ title: "Site", text: "网站", target: "https://EXAMPLE.invalid/path" }),
    Metadata.Link({ title: "Local", text: "文件", target: "file:///private/tmp/a" }),
  ] }) }), {});
  assert.deepEqual(reply.detail.metadata, [
    { kind: "link", title: "Site", text: "网站", target: "https://example.invalid/path" },
    { kind: "label", title: "Local", text: "文件" },
  ]);
});

test("explicit Paste actions accept text, numeric and text object content", async () => {
  assert.equal(PasteAction, Action.Paste);
  assert.equal(Action.Style.Regular, "regular");
  const cases = [
    [Detail, "文本", "文本"],
    [Grid, 42, "42"],
    [List, { text: "剪贴" }, "剪贴"],
  ];
  for (const [View, content, text] of cases) {
    const actions = ActionPanel({ children: Action.Paste({ content }) });
    const command = () => View === Detail ? View({ actions }) : View({ children: View.Item({ title: "Entry", actions }) });
    const snapshot = await render(command, {});
    const entry = snapshot.detail ?? snapshot.rows?.[0] ?? snapshot.grid.sections[0].items[0];
    assert.equal(entry.actions[0].title, "Paste in Active App");
    assert.equal(entry.actions[0].kind, "paste");
    assert.deepEqual(await render(command, { action: { row: 0, id: 0 } }), { kind: "paste", text });
  }
});

test("Paste actions accept file URLs and HTML, and reject invalid or oversized content", async () => {
  const action = { row: 0, id: 0 };
  const command = (content) => () => Detail({ actions: ActionPanel({ children: Action.Paste({ content }) }) });
  for (const [content, clipboardContent] of [
    [{ file: new URL("file:///private/tmp/a") }, { file: "/private/tmp/a" }],
    [{ html: "<b>value</b>", text: "value" }, { html: "<b>value</b>", text: "value" }],
  ]) {
    assert.deepEqual(await render(command(content), { action }), { kind: "paste", clipboardContent });
  }
  await assert.rejects(render(command({ file: "relative/file" }), { action }), /bounded absolute file path/);
  await assert.rejects(render(command(Infinity), { action }), /Expected text/);
  await assert.rejects(render(command("字".repeat(1366)), { action }), /Expected bounded clipboard text/);
});
