const assert = require("node:assert/strict");
const test = require("node:test");
const {
  Action, ActionPanel, Form, FormDatePicker, FormDropdownSection, FormTagPicker, FormTagPickerItem,
  Grid, List, LocalStorage, render, useEffect, useState,
} = require("./view-api.cjs");

const entries = [
  { title: "红色", category: "warm" },
  { title: "蓝色", category: "cool" },
  { title: "蓝绿色", category: "cool" },
];

function catalog(View) {
  return () => {
    const [filter, setFilter] = useState(() => ({ category: "all", query: "" }));
    const [matches, setMatches] = useState([]);
    useEffect(() => {
      setMatches(entries.filter(({ category, title }) =>
        (filter.category === "all" || filter.category === category) && title.includes(filter.query)));
    }, [filter]);
    const Dropdown = View.Dropdown;
    return View({
      onSearchTextChange: (query) => setFilter((state) => ({ ...state, query })),
      searchBarAccessory: Dropdown({
        value: filter.category,
        onChange: (category) => setFilter((state) => ({ ...state, category })),
        children: Dropdown.Section({ title: "颜色", children: [
          Dropdown.Item({ title: "全部", value: "all" }),
          Dropdown.Item({ title: "暖色", value: "warm" }),
          Dropdown.Item({ title: "冷色", value: "cool" }),
        ] }),
      }),
      children: matches.map(({ title }) => View.Item({
        title, content: title,
        actions: ActionPanel({ children: Action.CopyToClipboard({ title: "Copy", content: title }) }),
      })),
    });
  };
}

test("List and Grid reconstruct dropdown and search before effects and action lookup", async () => {
  for (const View of [List, Grid]) {
    const command = catalog(View);
    const input = { query: "绿色", dropdownValue: "cool", dropdownSelectionEvent: true };
    const reply = await render(command, input);
    assert.equal(reply.dropdown.selected, "cool");
    const rows = reply.rows ?? reply.grid.sections.flatMap((section) => section.items);
    assert.deepEqual(rows.map(({ title }) => title), ["蓝绿色"]);
    assert.deepEqual(await render(command, { query: "绿色", dropdownValue: "cool", action: { row: 0, id: 0 } }),
      { kind: "copy", text: "蓝绿色" });
  }
});

test("a stale dropdown falls back on render and rejects explicit changes or actions", async () => {
  const command = catalog(List);
  assert.equal((await render(command, { query: "", dropdownValue: "stale" })).dropdown.selected, "all");
  await assert.rejects(render(command, { query: "", dropdownValue: "stale", dropdownSelectionEvent: true }),
    /Invalid dropdown selection/);
  await assert.rejects(render(command, { query: "", dropdownValue: "stale", action: { row: 0, id: 0 } }),
    /Invalid dropdown selection/);
});

test("reconstructed search callbacks cannot write LocalStorage", async () => {
  const command = () => List({
    onSearchTextChange: (query) => LocalStorage.setItem("query", query),
  });
  await assert.rejects(render(command, { query: "synthetic", storage: {} }), /reconstructing view inputs/);
});

test("deprecated advanced Form names share the same components", () => {
  assert.equal(FormDatePicker, Form.DatePicker);
  assert.equal(FormDropdownSection, Form.Dropdown.Section);
  assert.equal(FormTagPicker, Form.TagPicker);
  assert.equal(FormTagPickerItem, Form.TagPicker.Item);
});
