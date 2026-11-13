const assert = require("node:assert/strict");
const test = require("node:test");
const { Action, ActionPanel, Detail, List, render } = require("./view-api.cjs");

const { Metadata } = Detail;
const command = () => Detail({
  markdown: "**Hello** _详情_",
  navigationTitle: "Preview",
  isLoading: true,
  metadata: Metadata({ children: [
    Metadata.Label({ title: "Version", text: { value: "1.0" } }),
    Metadata.Separator({}),
    Metadata.TagList({ title: "Tags", children: [
      Metadata.TagList.Item({ text: "Swift", color: { light: "#abc", dark: "#123456" } }),
      Metadata.TagList.Item({ icon: "Folder" }),
    ] }),
    Metadata.TagList({ title: "Empty", children: null }),
  ] }),
  actions: ActionPanel({ children: [
    Action.CopyToClipboard({ title: "Copy", content: "sample" }),
    Action({ title: "Run", style: Action.Style.Destructive, onAction: () => {} }),
  ] }),
});

test("standalone detail renders its document, metadata and actions", async () => {
  const { kind, detail } = await render(command, {});
  assert.equal(kind, "detail");
  assert.equal(detail.markdown, "**Hello** _详情_");
  assert.equal(detail.navigationTitle, "Preview");
  assert.equal(detail.isLoading, true);
  assert.deepEqual(JSON.parse(JSON.stringify(detail.metadata)), [
    { kind: "label", title: "Version", text: "1.0" },
    { kind: "separator" },
    { kind: "tags", title: "Tags", tags: [
      { text: "Swift", color: "#abc", darkColor: "#123456" },
      { icon: "Folder" },
    ] },
    { kind: "tags", title: "Empty", tags: [] },
  ]);
  assert.deepEqual(detail.actions.map(({ id, kind, destructive }) => [id, kind, destructive]), [
    [0, "copy", false], [1, "callback", true],
  ]);
});

test("detail actions share the view action flow", async () => {
  assert.deepEqual(await render(command, { action: { row: 0, id: 0 } }), { kind: "copy", text: "sample" });
  assert.deepEqual(await render(command, { action: { row: 0, id: 1 } }), { kind: "action" });
  await assert.rejects(render(command, { action: { row: 1, id: 0 } }), /Unknown detail/);
});

test("list row detail retains its existing wire format", async () => {
  const { Detail: RowDetail } = List.Item;
  const result = await render(() => List({ children: List.Item({
    title: "Row",
    detail: RowDetail({
      markdown: "old view",
      metadata: RowDetail.Metadata({ children: RowDetail.Metadata.Label({ title: "One", text: "Two" }) }),
    }),
  }) }), {});
  assert.equal(result.kind, "view");
  assert.equal(result.rows[0].markdown, "old view");
  assert.deepEqual(result.rows[0].metadata, [{ title: "One", text: "Two" }]);
});
