const assert = require("node:assert/strict");
const test = require("node:test");
const { describeListMetadata, listMetadataComponents } = require("./list-metadata.cjs");
const { webURL } = require("./open-api.cjs");

const component = (type) => (props = {}) => ({ type, props });
const children = (node) => [node?.props?.children].flat(Infinity).filter(Boolean);
const { Link, TagList } = listMetadataComponents(component);
const panel = component("metadata");
const label = component("label");
const separator = component("separator");

test("new metadata preserves ordered labels, links, separators and styled tags", () => {
  const rows = describeListMetadata(panel({ children: [
    label({ title: "Name", text: { value: "名称" } }),
    Link({ title: "Docs", text: "阅读文档", target: "HTTPS://Example.COM/Guide" }),
    separator(),
    TagList({ title: "Tags", children: [
      TagList.Item({ text: "标签", color: { light: "#abc", dark: "#123456" } }),
      TagList.Item({ icon: { source: "Folder" }, color: "raycast-blue" }),
    ] }),
  ] }), children, webURL);
  assert.deepEqual(JSON.parse(JSON.stringify(rows)), [
    { kind: "label", title: "Name", text: "名称" },
    { kind: "link", title: "Docs", text: "阅读文档", target: "https://example.com/Guide" },
    { kind: "separator" },
    { kind: "tags", title: "Tags", tags: [
      { text: "标签", color: "#abc", darkColor: "#123456" },
      { icon: "Folder", color: "raycast-blue" },
    ] },
  ]);
});

test("unsafe link targets stay inert and only reviewed tag fields are carried", () => {
  let called = false;
  const badTargets = ["file:///etc/hosts", "https://user:pass@example.com", "javascript:alert(1)", "https://example.com/%00"];
  const rows = describeListMetadata(panel({ children: [
    ...badTargets.map((target, index) => Link({ title: "Link", text: String(index), target })),
    TagList({ title: "Tags", children: [
      TagList.Item({ icon: "https://example.com/image.png" }),
      TagList.Item({ text: "Label", color: "red", onAction: () => { called = true; } }),
    ] }),
  ] }), children, webURL);
  assert(rows.slice(0, -1).every((row) => row.kind === "label" && row.target === undefined));
  const [tag] = rows.at(-1).tags;
  assert.equal(tag.text, "Label");
  assert.match(tag.actionReceipt, /^[a-f0-9]{64}$/);
  assert.equal(called, false);
});

test("a label with a dynamic color or icon uses the rich wire even when it is the only row", async () => {
  const { Detail, Icon, List, render } = require("./view-api.cjs");
  const labelProps = { title: "Status", text: { value: "可用", color: { light: "#080", dark: "#0f0" } },
    icon: { source: Icon.Circle, tintColor: "#f00" } };
  const standalone = await render(() => Detail({ metadata: Detail.Metadata({ children: Detail.Metadata.Label(labelProps) }) }), {});
  const RowDetail = List.Item.Detail;
  const row = (await render(() => List({ children: List.Item({ title: "Row",
    detail: RowDetail({ isLoading: true, markdown: "## Detail", metadata: RowDetail.Metadata({
      children: RowDetail.Metadata.Label(labelProps),
    }) }),
  }) }), {})).rows[0];
  assert.equal(row.detailLoading, true);
  assert.equal(row.markdown, "## Detail");
  const [styled] = row.richMetadata;
  assert.deepEqual(styled, standalone.detail.metadata[0]);
  assert.equal(styled.text, "可用");
  assert.equal(styled.color, "#080");
  assert.equal(styled.darkColor, "#0f0");
  assert.equal(styled.imageDescriptor.light.symbol, Icon.Circle);
  assert.equal(styled.imageDescriptor.tintColor, "#f00");
});

test("metadata tags require a receipt for the current row and refresh the clicked view", async () => {
  const { Detail, List, render, useState } = require("./view-api.cjs");
  let activations = 0;
  const RowDetail = List.Item.Detail;
  function command() {
    const [value, setValue] = useState("before");
    return List({ children: ["first", "second"].map((id) => List.Item({ id, title: id,
      detail: RowDetail({ markdown: value, metadata: RowDetail.Metadata({ children: RowDetail.Metadata.TagList({
        title: "Flags", children: [RowDetail.Metadata.TagList.Item({ text: "static" }),
          RowDetail.Metadata.TagList.Item({ text: "click", onAction() { activations++; setValue(id); } })],
      }) }) }),
    })) });
  }
  const snapshot = await render(command, {});
  const first = snapshot.rows[0].richMetadata[0].tags;
  const second = snapshot.rows[1].richMetadata[0].tags;
  assert.equal(first[0].actionReceipt, undefined);
  assert.notEqual(first[1].actionReceipt, second[1].actionReceipt);
  assert.equal(activations, 0);
  const action = { row: 1, id: 0 };
  await assert.rejects(render(command, { action, metadataTagReceipt: first[1].actionReceipt }), /Invalid metadata tag action/);
  const updated = await render(command, { action, metadataTagReceipt: second[1].actionReceipt });
  assert.equal(updated.rows[1].markdown, "second");
  assert.equal(activations, 1);

  const standalone = () => Detail({ metadata: Detail.Metadata({ children: Detail.Metadata.TagList({
    title: "Flags", children: Detail.Metadata.TagList.Item({ text: "click", onAction() { activations++; } }),
  }) }) });
  const { actionReceipt } = (await render(standalone, {})).detail.metadata[0].tags[0];
  await assert.rejects(render(standalone, { action: { row: 1, id: 0 }, metadataTagReceipt: actionReceipt }), /Invalid metadata tag action/);
  assert.equal((await render(standalone, { action: { row: 0, id: 0 }, metadataTagReceipt: actionReceipt })).kind, "detail");
  assert.equal(activations, 2);
});

test("legacy label-only panels keep the old wire and rich rows have size limits", () => {
  assert.equal(describeListMetadata(panel({ children: label({ title: "Legacy", text: "text" }) }), children, webURL), undefined);
  const tag = TagList.Item({ text: "tag" });
  const limited = describeListMetadata(panel({ children: [
    TagList({ title: "Tags", children: Array(30).fill(tag) }),
    ...Array(40).fill(label({ title: "Labels", text: "text" })),
  ] }), children, webURL);
  assert.equal(limited.length, 32);
  assert.equal(limited[0].tags.length, 24);
});

test("reviewed List emits richer metadata alongside legacy labels only when used", async () => {
  const { List, render } = require("./view-api.cjs");
  const Detail = List.Item.Detail;
  const { Metadata } = Detail;
  const command = () => List({ children: [
    List.Item({
      title: "Legacy",
      detail: Detail({ markdown: "# Legacy", metadata: Metadata({ children: [
        Metadata.Label({ title: "Version", text: "1.0" }),
      ] }) }),
    }),
    List.Item({
      title: "New metadata",
      detail: Detail({ metadata: Metadata({ children: [
        Metadata.Label({ title: "Version", text: "2.0" }),
        Metadata.Link({ title: "Guide", text: "Read guide", target: "https://example.com/guide" }),
        Metadata.TagList({ title: "Tags", children: Metadata.TagList.Item({ text: "Swift" }) }),
      ] }) }),
    }),
  ] });
  const { rows } = await render(command, { query: "" });
  assert.deepEqual(rows[0].metadata, [{ title: "Version", text: "1.0" }]);
  assert.equal(rows[0].richMetadata, undefined);
  assert.deepEqual(rows[1].metadata, [{ title: "Version", text: "2.0" }]);
  assert.equal(rows[1].markdown, undefined);
  assert.deepEqual(JSON.parse(JSON.stringify(rows[1].richMetadata)), [
    { kind: "label", title: "Version", text: "2.0" },
    { kind: "link", title: "Guide", text: "Read guide", target: "https://example.com/guide" },
    { kind: "tags", title: "Tags", tags: [{ text: "Swift" }] },
  ]);
});

test("metadata separators survive in rows with only labels and separators", async () => {
  const { List, render } = require("./view-api.cjs");
  const { Detail } = List.Item;
  const { Metadata } = Detail;
  const { rows } = await render(() => List({ children: List.Item({
    title: "Example",
    detail: Detail({ metadata: Metadata({ children: [
      Metadata.Label({ title: "First", text: "One" }),
      Metadata.Separator({}),
      Metadata.Label({ title: "Second", text: "Two" }),
    ] }) }),
  }) }), {});
  assert.deepEqual(rows[0].richMetadata, [
    { kind: "label", title: "First", text: "One" },
    { kind: "separator" },
    { kind: "label", title: "Second", text: "Two" },
  ]);
});

test("standalone and row metadata serialize the same link and keep unsafe targets inert", async () => {
  const { Detail, List, render } = require("./view-api.cjs");
  const props = { title: "Reference", text: "查阅", target: "https://example.com/文档?q=日历#section" };
  function metadata(View, target) {
    return View.Metadata({ children: View.Metadata.Link({ ...props, target }) });
  }
  for (const [target, expected] of [
    [props.target, { kind: "link", title: props.title, text: props.text, target: new URL(props.target).href }],
    ["file:///etc/hosts", { kind: "label", title: props.title, text: props.text }],
  ]) {
    const standalone = await render(() => Detail({ metadata: metadata(Detail, target) }), {});
    const RowDetail = List.Item.Detail;
    const list = await render(() => List({ isShowingDetail: true, children: List.Item({
      title: "Row", detail: RowDetail({ metadata: metadata(RowDetail, target) }),
    }) }), {});
    assert.deepEqual(standalone.detail.metadata[0], expected);
    assert.deepEqual(list.rows[0].richMetadata[0], expected);
  }
});
