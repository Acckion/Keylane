const assert = require("node:assert/strict");
const test = require("node:test");
const api = require("./view-api.cjs");
const { MenuBarExtra: Menu, Keyboard } = api;

const input = { wallTime: 1 };
const command = () => Menu({ tooltip: "Status", children: [
  Menu.Section({ title: "Tasks", children: Menu.Item({ title: "No tasks" }) }),
  Menu.Separator(),
  Menu.Submenu({ title: "Tools", children: Menu.Item({
    title: "Preferences", subtitle: "Extension", tooltip: "Open settings",
    shortcut: Keyboard.Shortcut.Common.MoveDown,
    onAction(event) {
      assert.equal(event.type, "left-click");
      return api.openCommandPreferences();
    },
  }) }),
] });

test("menu structure and shortcut survive guest serialization and nested action replay", async () => {
  const snapshot = await api.runMenuBar(command, input);
  assert.equal(snapshot.tooltip, "Status");
  assert.deepEqual(snapshot.items.map(({ kind }) => kind), ["section", "separator", "submenu"]);
  assert.equal(snapshot.items[0].children[0].enabled, false);
  const action = snapshot.items[2].children[0];
  assert.equal(action.key, "arrowDown");
  assert.deepEqual(action.modifiers, ["cmd", "opt"]);
  assert.equal(action.subtitle, "Extension");
  assert.equal(action.tooltip, "Open settings");
  const reply = await api.runMenuBar(command, { ...input, menuAction: action.id });
  assert.deepEqual(reply, { kind: "openPreferences" });
  await assert.rejects(api.runMenuBar(command, { ...input, menuAction: 0 }), /Unknown menu action/);
});

test("guest menu tree has a bounded node count and depth", async () => {
  const large = () => Menu({ children: Array.from({ length: 65 }, () => Menu.Item({ title: "Item" })) });
  await assert.rejects(api.runMenuBar(large, input), /Menu tree limit exceeded/);
  let node = Menu.Item({ title: "Item" });
  for (let index = 0; index < 5; index++) node = Menu.Submenu({ title: "Submenu", children: node });
  await assert.rejects(api.runMenuBar(() => Menu({ children: node }), input), /Menu tree limit exceeded/);
});
