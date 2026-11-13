const assert = require("node:assert/strict");
const test = require("node:test");
const { listNodes, listText } = require("./list-api.cjs");

function node(type, props = {}) {
  return { type, props };
}

function children(parent) {
  return [parent.props.children].flat(Infinity).filter(Boolean);
}

const item = (title, keywords) => node("item", { title, keywords });
const nested = node("section", {
  title: "Palette",
  children: [
    item("Blue", ["蓝色"]),
    item("Café", ["beverage"]),
  ],
});
const existingTitle = { value: "Open Editor", tooltip: "Open your editor" };

test("default title and keyword matching handles accents, CJK and wrapped titles", () => {
  const root = node("list", { children: [item(existingTitle, []), nested] });
  const find = (query) => listNodes(root, query, children).nodes.map(({ item, section }) => [listText(item.props.title), section]);
  assert.deepEqual(find("o ed"), [["Open Editor", undefined]]);
  assert.deepEqual(find("CAFE bev"), [["Café", "Palette"]]);
  assert.deepEqual(find("蓝色"), [["Blue", "Palette"]]);
  assert.deepEqual(find(" 	 "), [["Open Editor", undefined], ["Blue", "Palette"], ["Café", "Palette"]]);
  assert.deepEqual(find("absent"), []);
});

test("custom or explicitly disabled filtering preserves extension-managed results", () => {
  const row = item("Not a valid permission mode", []);
  const expects = (props, count) => {
    const result = listNodes(node("list", { children: row, ...props }), "garbage", children);
    assert.equal(result.nodes.length, count);
  };
  const onSearchTextChange = () => assert.fail("The filter must leave callback delivery to the view lifecycle");
  expects({ filtering: false }, 1);
  expects({ enableFiltering: false }, 1);
  expects({ onSearchTextChange }, 1);
  expects({ filtering: true, onSearchTextChange }, 0);
  expects({ filtering: { keepSectionOrder: true }, onSearchTextChange }, 0);
});

test("empty state keeps its explicit actions and allows only built-in icons", () => {
  const panel = node("actions");
  const rootPanel = node("actions", { title: "Root" });
  const empty = node("listEmpty", { title: "Nothing found", description: "Try again", icon: { source: "Folder" }, actions: panel });
  const root = node("list", { children: [nested, empty], actions: rootPanel });
  assert.equal(listNodes(root, "blue", children).empty, undefined);
  assert.deepEqual(listNodes(root, "absent", children).empty, {
    title: "Nothing found", description: "Try again", icon: "Folder", panel,
  });

  empty.props.icon = { source: "https://example.invalid/asset.png" };
  assert.equal(listNodes(root, "absent", children).empty.icon, undefined);
  assert.equal(listNodes(node("list", { children: nested, actions: rootPanel }), "absent", children).empty.panel, undefined);
  assert.equal(listNodes(node("list", { actions: rootPanel }), "", children).empty.panel, rootPanel);
});

test("empty search suppresses the empty state while loading", () => {
  const root = node("list", { children: node("listEmpty", { title: "Waiting" }), isLoading: true });
  assert.equal(listNodes(root, "", children).empty, undefined);
  assert.equal(listNodes(root, "typed", children).empty.title, "Waiting");
});

test("filtered view and empty-state action replay target the serialized rows", async () => {
  const { List, Action, ActionPanel, render } = require("./view-api.cjs");
  const copy = (content) => ActionPanel({ children: Action.CopyToClipboard({ content }) });
  const command = () => List({ children: [
    List.Item({ title: "Café", actions: copy("coffee") }),
    List.Section({ title: "Palette", children: List.Item({
      title: { value: "Blue", tooltip: "Colour" },
      subtitle: { value: "Cool", tooltip: "Temperature" },
      keywords: ["蓝色"],
      actions: copy("blue"),
    }) }),
    List.EmptyView({ title: "No matches", actions: copy("empty") }),
  ] });

  const { rows } = await render(command, { query: "蓝色" });
  assert.deepEqual(rows.map(({ id, title, subtitle, section }) => [id, title, subtitle, section]), [[0, "Blue", "Cool", "Palette"]]);
  assert.deepEqual(await render(command, { query: "蓝色", action: { row: 0, id: 0 } }), { kind: "copy", text: "blue" });
  await assert.rejects(render(command, { query: "蓝色", action: { row: -1, id: 0 } }), /Unknown action/);

  const { empty } = await render(command, { query: "unknown" });
  assert.equal(empty.title, "No matches");
  assert.deepEqual(await render(command, { query: "unknown", action: { row: -1, id: 0 } }), { kind: "copy", text: "empty" });
});

test("List.Section and ListSection retain titles and subtitles through filtering", async () => {
  const { List, ListSection, render } = require("./view-api.cjs");
  assert.equal(ListSection, List.Section);
  const { rows } = await render(() => List({ children: [
    List.Section({ title: "Group", subtitle: "First", children: [
      List.Item({ title: "Hidden" }), List.Item({ title: "Match one" }),
    ] }),
    ListSection({ title: "Group", subtitle: "Second", children: List.Item({ title: "Match two" }) }),
    List.Section({ subtitle: "Only subtitle", children: List.Item({ title: "Match three" }) }),
  ] }), { query: "Match" });
  assert.deepEqual(rows.map(({ title, section, sectionSubtitle, sectionID }) => [title, section, sectionSubtitle, sectionID]), [
    ["Match one", "Group", "First", 0], ["Match two", "Group", "Second", 1],
    ["Match three", undefined, "Only subtitle", 2],
  ]);
});

test("list keeps stable section identity and replays the action on ranked results", async () => {
  const { List, Action, ActionPanel, render } = require("./view-api.cjs");
  const command = (filtering) => () => List({ filtering, children: [
    List.Section({ title: "Same", subtitle: "First", children: List.Item({ title: "Café bar" }) }),
    List.Section({ title: "Same", subtitle: "Second", children: List.Item({
      title: "Café", actions: ActionPanel({ children: Action.CopyToClipboard({ content: "exact" }) }),
    }) }),
  ] });
  const query = "cafe";
  const ranked = await render(command(true), { query });
  assert.deepEqual(ranked.rows.map(({ title, sectionID }) => [title, sectionID]), [["Café", 1], ["Café bar", 0]]);
  const id = ranked.rows[0].id;
  assert.deepEqual(await render(command(true), { query, action: { row: id, id: 0 } }),
    { kind: "copy", text: "exact" });
  const fixed = await render(command({ keepSectionOrder: true }), { query });
  assert.deepEqual(fixed.rows.map(({ sectionID }) => sectionID), [0, 1]);
});
