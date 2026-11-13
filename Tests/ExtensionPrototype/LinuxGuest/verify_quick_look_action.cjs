const assert = require("node:assert/strict");
const { test } = require("node:test");
const { quickLookComponent, quickLookEffect } = require("./quick-look-action.cjs");

test("constructing a Quick Look action leaves the preview target on the row", () => {
  const ToggleQuickLook = quickLookComponent((type) => (props) => ({ type, props }));
  assert.deepEqual(ToggleQuickLook(), {
    type: "toggleQuickLook",
    props: { title: "Quick Look", icon: "eye-16" },
  });
  assert.equal(ToggleQuickLook({ title: "Preview report" }).props.title, "Preview report");
});

test("Quick Look emits only a validated local path from the selected row metadata", () => {
  const path = "/private/tmp/测试 文件.pdf";
  const expected = { kind: "toggleQuickLook", paths: [path] };
  assert.deepEqual(quickLookEffect({ path, name: "Report" }), { ...expected, previewTitle: "Report" });
  assert.deepEqual(quickLookEffect({ path: "~/Downloads/测试 文件.pdf", name: null }), {
    kind: "toggleQuickLook", paths: ["~/Downloads/测试 文件.pdf"],
  });
  assert.throws(() => quickLookEffect({ path, name: "Invalid\nTitle" }), /Invalid Quick Look name/);
  assert.deepEqual(quickLookEffect({ path: Buffer.from(path) }), expected);
  assert.deepEqual(quickLookEffect({ path: new URL("file:///private/tmp/%E6%B5%8B%E8%AF%95%20%E6%96%87%E4%BB%B6.pdf") }), expected);
  assert.throws(() => quickLookEffect(), /selected item/);
  for (const path of ["./relative", "~/../report", "~someone/report", "/private/tmp/../report", "//remote/report", new URL("https://example.invalid/report")]) {
    assert.throws(() => quickLookEffect({ path }), TypeError);
  }
});

test("modern Open With and the legacy ActionPanel.Item reuse the reviewed actions", async () => {
  const { Action, ActionPanel, ActionPanelItem, Detail, OpenWithAction, render } = require("./view-api.cjs");
  assert.equal(Action.OpenWith, OpenWithAction);
  assert.equal(ActionPanel.Item, ActionPanelItem);
  assert.equal(ActionPanel.Item.ToggleQuickLook, Action.ToggleQuickLook);

  const path = "/private/tmp/Example.txt";
  const command = () => Detail({ actions: ActionPanel({ children: [
    Action.OpenWith({ path }),
    ActionPanel.Item.CopyToClipboard({ content: "example" }),
  ] }) });
  const select = (id) => render(command, { action: { row: 0, id } });
  assert.deepEqual(await select(0), { kind: "openWithFile", paths: [path] });
  assert.deepEqual(await select(1), { kind: "copy", text: "example" });
});

test("only an explicitly selected filtered List or Grid row can request Quick Look", async () => {
  const { Action, ActionPanel, Detail, Grid, List, render } = require("./view-api.cjs");
  const path = "/private/tmp/选中 文件.pdf";
  const actions = () => ActionPanel({ children: Action.ToggleQuickLook() });
  const entries = [
    { title: "Other", quickLook: { path: "/private/tmp/other.pdf" } },
    { title: "Selected", quickLook: { path } },
  ];
  const list = () => List({ children: entries.map((entry) => List.Item({ ...entry, actions: actions() })) });
  const grid = () => Grid({ children: entries.map((entry) => Grid.Item({ ...entry, actions: actions(), content: "📄" })) });
  const query = "Selected";

  const listSnapshot = await render(list, { query });
  assert.equal(listSnapshot.kind, "view");
  assert.equal(listSnapshot.rows[0].actions[0].kind, "toggleQuickLook");
  const gridSnapshot = await render(grid, { query });
  assert.equal(gridSnapshot.kind, "grid");
  const listRow = listSnapshot.rows[0].id;
  const gridRow = gridSnapshot.grid.sections[0].items[0].id;
  const expected = { kind: "toggleQuickLook", paths: [path] };
  assert.deepEqual(await render(list, { query, action: { row: listRow, id: 0 } }), expected);
  assert.deepEqual(await render(grid, { query, action: { row: gridRow, id: 0 } }), expected);
  await assert.rejects(render(grid, { query, action: { row: -1, id: 0 } }), /Unknown grid item/);
  await assert.rejects(render(() => Detail({ actions: actions() }), { action: { row: 0, id: 0 } }), /selected item/);
});
