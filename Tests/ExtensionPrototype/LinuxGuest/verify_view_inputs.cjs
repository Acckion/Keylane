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

test("catalog no-view commands run without rendering and commit cache on normal completion", async () => {
  const { runCommand, Cache, getPreferenceValues } = require("./view-api.cjs");
  const { configureEnvironment } = require("./environment.cjs");
  configureEnvironment({ launchType: "userInitiated", entryPointMode: "no-view" });
  const result = await runCommand(async (props) => {
    assert.deepEqual(props, { arguments: {}, launchType: "userInitiated" });
    assert.deepEqual(getPreferenceValues(), { title: "fixture" });
    new Cache().set("run", "done");
  }, { catalogNoView: true, preferences: { title: "fixture" }, cache: [] });
  assert.equal(result.kind, "action");
  assert.deepEqual(result.cache, [['["","run"]', "done"]]);
});

test("catalog no-view HUD awaits native presentation without a clipboard grant", async (t) => {
  const bridge = require("./raycast-api.cjs");
  const { runCommand, showHUD, PopToRootType } = require("./view-api.cjs");
  let acknowledge;
  let requested;
  const arrived = new Promise((resolve) => { requested = resolve; });
  const request = t.mock.method(bridge, "request", (kind, payload) => {
    requested([kind, JSON.parse(payload)]);
    return new Promise((resolve) => { acknowledge = resolve; });
  });
  let continued = false;
  const input = { catalogNoView: true };
  const result = runCommand(async () => {
    await showHUD("已呈现", { clearRootSearch: true, popToRootType: PopToRootType.Immediate });
    continued = true;
  }, input);
  assert.deepEqual(await arrived, ["feedback.hud", {
    text: "已呈现", clearRootSearch: true, popToRootType: "immediate",
  }]);
  assert.equal(continued, false);
  acknowledge("");
  assert.deepEqual(await result, { kind: "action" });
  assert.equal(continued, true);
  request.mock.mockImplementation(async () => { throw new Error("Host rejected HUD"); });
  await assert.rejects(runCommand(() => showHUD("Rejected"), input), /Host rejected HUD/);

  let lateHUD;
  await runCommand(async () => {
    lateHUD = new Promise((resolve) => setImmediate(() => resolve(
      assert.rejects(showHUD("Late"), /no-view command has ended/),
    )));
  }, input);
  await lateHUD;
  assert.equal(request.mock.callCount(), 2);
});

test("catalog no-view navigation awaits each host operation in order", async (t) => {
  const bridge = require("./raycast-api.cjs");
  const { runCommand, clearSearchBar, popToRoot, closeMainWindow, PopToRootType } = require("./view-api.cjs");
  const calls = [];
  let received;
  const request = t.mock.method(bridge, "request", (kind, payload) => new Promise((acknowledge) => {
    calls.push([kind, JSON.parse(payload)]);
    received(acknowledge);
  }));
  let arriving = new Promise((resolve) => { received = resolve; });
  let finished = false;
  const result = runCommand(async () => {
    await clearSearchBar({ forceScrollToTop: false });
    await popToRoot({ clearSearchBar: true });
    await closeMainWindow({ popToRootType: PopToRootType.Suspended });
    finished = true;
  }, { catalogNoView: true });
  const expected = [
    ["navigation.clearSearch", { forceScrollToTop: false }],
    ["navigation.popToRoot", { clearSearchBar: true }],
    ["navigation.closeWindow", { clearRootSearch: false, popToRootType: "suspended" }],
  ];
  for (let index = 0; index < expected.length; index++) {
    const acknowledge = await arriving;
    assert.deepEqual(calls, expected.slice(0, index + 1));
    assert.equal(finished, false);
    arriving = new Promise((resolve) => { received = resolve; });
    acknowledge("");
  }
  assert.deepEqual(await result, { kind: "action" });
  assert.equal(finished, true);
  request.mock.mockImplementation(async () => { throw new Error("Host rejected navigation"); });
  for (const navigate of [clearSearchBar, popToRoot, closeMainWindow]) {
    await assert.rejects(runCommand(() => navigate(), { catalogNoView: true }), /Host rejected navigation/);
  }
});
