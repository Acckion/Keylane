const assert = require("node:assert/strict");
const test = require("node:test");
const { dropdownComponent, describeDropdown, applyDropdownSelection } = require("./dropdown-api.cjs");

const component = (type) => (props = {}) => ({ type, props });
const children = (node) => [node?.props?.children].flat(Infinity).filter(Boolean);
const Dropdown = dropdownComponent(component);
const root = (props = {}) => ({ props: { searchBarAccessory: Dropdown({
  tooltip: "Choose",
  placeholder: "Search categories",
  children: [
    Dropdown.Item({ value: "all", title: "All" }),
    Dropdown.Section({ title: "Languages", children: [
      Dropdown.Item({ value: "zh", title: "中文", icon: "Folder", keywords: ["Chinese"] }),
      Dropdown.Item({ value: "en", title: "English", icon: "https://example.invalid/image.png" }),
    ] }),
  ],
  ...props,
}) } });

test("groups options, preserves search metadata, and lets controlled values take precedence", () => {
  const result = describeDropdown(root({ value: "zh", defaultValue: "en" }), children, "all");
  assert.equal(result.selected, "zh");
  assert.equal(result.placeholder, "Search categories");
  assert.deepEqual(result.sections.map(({ title, items }) => [title, items.map(({ value }) => value)]), [
    [undefined, ["all"]], ["Languages", ["zh", "en"]],
  ]);
  assert.deepEqual(result.sections[1].items[0].keywords, ["Chinese"]);
  assert.equal(result.sections[1].items[0].icon, "Folder");
  assert.equal(result.sections[1].items[1].icon, undefined);
  assert.equal(describeDropdown(root({ defaultValue: "en" }), children).selected, "en");
  assert.equal(describeDropdown(root({ defaultValue: "en" }), children, "zh").selected, "zh");
  assert.equal(describeDropdown(root({ defaultValue: "unknown" }), children).selected, "all");
});

test("replays only a valid changed value and tolerates an explicitly passive stale selection", async () => {
  const received = [];
  const dropdown = root({ defaultValue: "all", async onChange(value) { received.push(value); } });
  assert.equal(await applyDropdownSelection(dropdown, children, "zh"), true);
  await applyDropdownSelection(dropdown, children, "all");
  await assert.rejects(applyDropdownSelection(dropdown, children, "unknown"), /Invalid dropdown selection/);
  await assert.rejects(applyDropdownSelection(dropdown, children, { value: "zh" }), /Invalid dropdown selection/);
  assert.equal(await applyDropdownSelection(dropdown, children, "unknown", { strict: false }), false);
  assert.deepEqual(received, ["zh"]);
});

test("rejects duplicate values across sections and excessive or malformed options", () => {
  assert.throws(() => describeDropdown(root({ children: [
    Dropdown.Item({ value: "dup", title: "First" }),
    Dropdown.Section({ children: Dropdown.Item({ value: "dup", title: "Second" }) }),
  ] }), children), /Invalid dropdown item value or title/);
  assert.throws(() => describeDropdown(root({ children: Dropdown.Item({ value: 1, title: "Item" }) }), children),
    /Invalid dropdown item value or title/);
  assert.throws(() => describeDropdown(root({ children: Array.from({ length: 65 },
    (_, index) => Dropdown.Item({ value: String(index), title: "Item" })) }), children), /Invalid dropdown item value or title/);
  assert.equal(describeDropdown({}, children), undefined);
});

test("List and Grid replay a selection into controlled state before resolving the action", async () => {
  const { Action, ActionPanel, Grid, List, render, useEffect, useState } = require("./view-api.cjs");
  for (const View of [List, Grid]) {
    function command() {
      const [category, setCategory] = useState(() => "all");
      const [title, setTitle] = useState("initial");
      useEffect(() => { setTitle(category === "zh" ? "中文项目" : "All items"); }, [category]);
      const Dropdown = View.Dropdown;
      const actions = ActionPanel({ children: Action.CopyToClipboard({ content: category }) });
      return View({
        searchBarAccessory: Dropdown({
          value: category,
          onChange: (value) => setCategory(() => value),
          children: [Dropdown.Item({ value: "all", title: "All" }), Dropdown.Item({ value: "zh", title: "中文" })],
        }),
        children: View.Item({ title, content: "★", actions }),
      });
    }

    const initial = await render(command, { query: "" });
    assert.equal(initial.dropdown.selected, "all");
    const picked = await render(command, { query: "", dropdownValue: "zh", dropdownSelectionEvent: true });
    assert.equal(picked.dropdown.selected, "zh");
    assert.equal(picked.kind === "view" ? picked.rows[0].title : picked.grid.sections[0].items[0].title, "中文项目");
    const copied = await render(command, { query: "", dropdownValue: "zh", action: { row: 0, id: 0 } });
    assert.deepEqual(copied, { kind: "copy", text: "zh" });
    await assert.rejects(render(command, { query: "", dropdownValue: "invalid", dropdownSelectionEvent: true }), /Invalid dropdown selection/);
    const stale = await render(command, { query: "", dropdownValue: "invalid" });
    assert.equal(stale.dropdown.selected, "all");
  }
});

test("List and Grid dropdown sections preserve unnamed and same-title groups", async () => {
  const { List, Grid, render } = require("./view-api.cjs");
  for (const Collection of [List, Grid]) {
    const Dropdown = Collection.Dropdown;
    const item = (value) => Dropdown.Item({ title: value, value });
    const reply = await render(() => Collection({
      searchBarAccessory: Dropdown({ tooltip: "Filter", children: [
        item("loose"),
        Dropdown.Section({ title: "Empty" }),
        Dropdown.Section({ children: item("untitled") }),
        Dropdown.Section({ title: "Same", children: item("first") }),
        Dropdown.Section({ title: "Same", children: item("second") }),
      ] }),
    }), {});
    assert.deepEqual(reply.dropdown.sections.map(({ title, items }) => [title, items.map(({ value }) => value)]), [
      [undefined, ["loose"]], [undefined, ["untitled"]], ["Same", ["first"]], ["Same", ["second"]],
    ]);
  }
});

test("dropdowns restore saved values by ID before building collection items", async () => {
  const { Grid, List, render, useState } = require("./view-api.cjs");
  for (const Collection of [List, Grid]) {
    const Dropdown = Collection.Dropdown;
    function command({ arguments: { input } }) {
      const [category, setCategory] = useState("all");
      return Collection({
        filtering: false,
        searchBarAccessory: Dropdown({
          id: input === "different" ? "other" : "category",
          value: input === "controlled" ? "all" : undefined,
          defaultValue: "all", storeValue: input !== "disabled",
          onChange: setCategory,
          children: [Dropdown.Item({ value: "all", title: "All" }), Dropdown.Item({ value: "zh", title: "中文" })],
        }),
        children: Collection.Item({ title: category, content: "★" }),
      });
    }
    const input = { query: "", dropdownPreferences: [["id:category", "zh"], ["default", "all"]] };
    const restored = await render(command, input);
    assert.equal(restored.dropdown.storageID, "id:category");
    assert.equal(restored.dropdown.selected, "zh");
    assert.equal(restored.kind === "view" ? restored.rows[0].title : restored.grid.sections[0].items[0].title, "zh");
    for (const query of ["different", "controlled", "disabled"]) {
      const result = await render(command, { ...input, query });
      assert.equal(result.dropdown.selected, "all");
    }
    assert.equal((await render(command, { ...input, dropdownValue: "all" })).dropdown.selected, "all");
    assert.equal((await render(command, { ...input, dropdownPreferences: [["id:category", "removed"]] })).dropdown.selected, "all");
  }
});

test("custom dropdown search is independent of the launcher query and replays a searched selection", async () => {
  const { Action, ActionPanel, Grid, List, render, useState } = require("./view-api.cjs");
  for (const Collection of [List, Grid]) {
    const Dropdown = Collection.Dropdown;
    function command() {
      const [menuQuery, setMenuQuery] = useState("");
      const [category, setCategory] = useState("all");
      return Collection({
        filtering: false,
        searchBarAccessory: Dropdown({
          tooltip: "Filter", value: category, onChange: setCategory, throttle: true,
          isLoading: menuQuery === "loading",
          onSearchTextChange: async (text) => {
            await new Promise(setImmediate);
            setMenuQuery(text);
          },
          children: menuQuery === "中文"
            ? Dropdown.Item({ value: "zh", title: "中文" })
            : Dropdown.Item({ value: "all", title: "All" }),
        }),
        children: Collection.Item({
          title: category, content: "★",
          actions: ActionPanel({ children: Action.CopyToClipboard({ content: category }) }),
        }),
      });
    }
    const options = await render(command, { query: "root", dropdownQuery: "中文" });
    assert.equal(options.kind, "dropdown");
    assert.equal(options.dropdown.nativeFiltering, false);
    assert.equal(options.dropdown.throttle, true);
    assert.equal(options.dropdown.sections[0].items[0].value, "zh");
    assert.equal((await render(command, { query: "root", dropdownQuery: "loading" })).dropdown.isLoading, true);

    const selection = { query: "root", dropdownValue: "zh", dropdownSelectionQuery: "中文" };
    const selected = await render(command, { ...selection, dropdownSelectionEvent: true });
    assert.equal(selected.dropdown.selected, "zh");
    const reopened = await render(command, { ...selection, dropdownQuery: "" });
    assert.equal(reopened.dropdown.sections[0].items[0].value, "all");
    assert.equal(reopened.dropdown.selectedItem.value, "zh");
    assert.deepEqual(await render(command, { ...selection, action: { row: 0, id: 0 } }), { kind: "copy", text: "zh" });
    await assert.rejects(render(command, { ...selection, dropdownSelectionQuery: "absent", dropdownSelectionEvent: true }),
      /Invalid dropdown selection/);
  }
});

test("dropdown search callbacks cannot write the reviewed extension cache", async () => {
  const { List, render } = require("./view-api.cjs");
  const { Cache } = require("./cache-api.cjs");
  const command = () => List({ searchBarAccessory: List.Dropdown({
    filtering: { keepSectionOrder: true },
    onSearchTextChange: () => new Cache().set("side-effect", "blocked"),
    children: List.Dropdown.Item({ value: "all", title: "All" }),
  }) });
  const initial = await render(command, { cache: [] });
  assert.equal(initial.dropdown.nativeFiltering, true);
  assert.equal(initial.dropdown.keepSectionOrder, true);
  await assert.rejects(render(command, { cache: [], dropdownQuery: "text" }), /Cache changes are unavailable/);
});
