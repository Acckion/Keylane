const assert = require("node:assert/strict");
const test = require("node:test");
const { creationActionComponents, creationActionEffect, makeOpenExtensionPreferences } = require("./create-actions.cjs");

const component = (type) => (props) => ({ type, props });
const { CreateQuicklink, CreateSnippet } = creationActionComponents(component);

test("quicklink actions carry editable templates and draft titles", () => {
  const link = "https://example.invalid/{路径}/?q={Query=中文 示例}&q2={Query=中文 示例}";
  const action = CreateQuicklink({ quicklink: { link, name: "搜索", icon: "Link" } });
  assert.equal(action.props.title, "Create Quicklink");
  assert.deepEqual(creationActionEffect(action), { kind: "createQuicklink", quicklink: { link, name: "搜索" } });
  assert.equal(CreateQuicklink({ title: "另一个操作", quicklink: { link } }).props.title, "另一个操作");
});

test("quicklink drafts reject non-web targets and unsafe or malformed templates", () => {
  for (const link of [
    "file:///private/tmp/a",
    "https://{Query}.invalid/",
    "https://example.invalid/{Query",
    "https://example.invalid/Query}",
    "https://example.invalid/?q={one=a}&q2={one=b}",
    "https://user@example.invalid/",
    "https://example.invalid/%0A",
    "https://example.invalid/has space",
    "https://example.invalid/" + "字".repeat(700),
  ]) {
    assert.throws(() => creationActionEffect(CreateQuicklink({ quicklink: { link } })), undefined, link);
  }
  assert.throws(() => creationActionEffect(CreateQuicklink({
    quicklink: { link: "https://example.invalid/", application: "com.apple.Safari" },
  })), /Custom quicklink applications/);
});

test("snippet drafts preserve multiline text and bound each field", () => {
  const snippet = { text: "第一行\n\tSecond line\r\n{date}", name: "回复", keyword: ";reply" };
  const action = CreateSnippet({ snippet });
  assert.equal(action.props.title, "Create Snippet");
  assert.deepEqual(creationActionEffect(action), { kind: "createSnippet", snippet });
  for (const invalid of [
    { text: "a\0b" }, { text: "字".repeat(1366) }, { text: 42 },
    { text: "ok", name: "字".repeat(86) }, { text: "ok", keyword: "x".repeat(129) },
  ]) {
    assert.throws(() => creationActionEffect(CreateSnippet({ snippet: invalid })), /Invalid snippet/);
  }
});

test("extension preferences request only the current extension and propagate denial", async () => {
  const effects = [];
  const open = makeOpenExtensionPreferences((effect) => effects.push(effect));
  assert.equal(await open({ page: "other-extension" }), undefined);
  assert.deepEqual(effects, [{ kind: "openExtensionPreferences" }]);
  const denied = makeOpenExtensionPreferences(() => { throw new Error("Requires a selected view action"); });
  await assert.rejects(denied(), /Requires a selected view action/);
});

test("selected view actions route drafts and current-extension preferences through the existing effect gate", async () => {
  const { Action, ActionPanel, Detail, List, openExtensionPreferences, render } = require("./view-api.cjs");
  const link = "https://example.invalid/search?q={Query}";
  const snippet = { text: "中文\nexample", name: "示例", keyword: ";example" };
  const command = () => Detail({ markdown: "Explicit actions", actions: ActionPanel({ children: [
    Action.CreateQuicklink({ quicklink: { link } }),
    Action.CreateSnippet({ snippet }),
    Action({ title: "Preferences", onAction: () => openExtensionPreferences() }),
  ] }) });
  const snapshot = await render(command, {});
  assert.deepEqual(snapshot.detail.actions.map(({ kind }) => kind), ["createQuicklink", "createSnippet", "callback"]);
  const effects = [
    { kind: "createQuicklink", quicklink: { link, name: undefined } },
    { kind: "createSnippet", snippet },
    { kind: "openExtensionPreferences" },
  ];
  for (const [id, effect] of effects.entries()) {
    assert.deepEqual(await render(command, { action: { row: 0, id } }), effect);
  }
  await assert.rejects(render(() => List({ onSearchTextChange: () => openExtensionPreferences() }), { query: "passive" }),
    /requires a selected view action/);
  assert.equal(require("./raycast-api.cjs").openExtensionPreferences, undefined);
});
