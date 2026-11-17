const assert = require("node:assert/strict");
const test = require("node:test");
const { creationActionComponents, creationActionEffect, makeOpenExtensionPreferences } = require("./create-actions.cjs");

const component = (type) => (props) => ({ type, props });
const { CreateQuicklink, CreateSnippet } = creationActionComponents(component);

test("quicklink actions carry editable templates and draft titles", () => {
  const link = "https://example.invalid/{路径}/?q={Query=中文 示例}&q2={Query=中文 示例}";
  const action = CreateQuicklink({ quicklink: { link, name: "搜索", icon: "Link" } });
  assert.equal(action.props.title, "Create Quicklink");
  assert.deepEqual(creationActionEffect(action), { kind: "createQuicklink", quicklink: { link, name: "搜索", icon: "Link" } });
  assert.equal(CreateQuicklink({ title: "另一个操作", quicklink: { link } }).props.title, "另一个操作");
});

test("quicklink drafts reject malformed URLs and unsafe local paths", () => {
  for (const link of [
    "file://remote/private/tmp/a",
    "file:///private/tmp/%2e%2e/a",
    "/private/tmp/../a",
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
    quicklink: { link: "https://example.invalid/", application: {} },
  })), /Invalid application selector/);
});

test("quicklink drafts preserve local targets and the application's selector", () => {
  const app = { bundleId: "com.apple.TextEdit", path: "/System/Applications/TextEdit.app", name: "TextEdit" };
  for (const link of ["/private/tmp/{Name}.txt", "~/Documents/{Name}", "file:///private/tmp/{Name}"]) {
    assert.deepEqual(creationActionEffect(CreateQuicklink({ quicklink: { link, application: app, icon: "folder-16" } })),
      { kind: "createQuicklink", quicklink: { link, name: undefined, application: app, icon: "folder-16" } });
  }
});

test("quicklink drafts preserve external URL templates and reject inline or templated hosts", () => {
  for (const link of ["keylane-probe://receive/{Value}", 'keylane-probe://receive/{argument name="Path Value"}', "mailto:{Address}?subject={Subject}", "tel:{Number}"]) {
    assert.equal(creationActionEffect(CreateQuicklink({ quicklink: { link } })).quicklink.link, link);
  }
  for (const link of ["javascript:alert(1)", "data:text/plain,hi", "keylane-probe://{Host}/run", "keylane-probe://user@receive/path", "{Scheme}://receive/path"]) {
    assert.throws(() => creationActionEffect(CreateQuicklink({ quicklink: { link } })), undefined, link);
  }
});

test("quicklink drafts carry dynamic placeholders unchanged for host validation", () => {
  const link = 'https://example.invalid/?q={clipboard | trim}&date={date format="yyyy-MM-dd" offset="+1d"}&snippet={snippet name="My Note"}';
  assert.equal(creationActionEffect(CreateQuicklink({ quicklink: { link } })).quicklink.link, link);
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
  assert.equal(typeof require("./raycast-api.cjs").openExtensionPreferences, "function");
});

test("preferences calls await the host and keep command and extension destinations distinct", async (t) => {
  const bridge = require("./raycast-api.cjs");
  const { Action, ActionPanel, Detail, openCommandPreferences, render } = require("./view-api.cjs");
  const calls = [];
  let release;
  const acknowledgment = new Promise((resolve) => { release = resolve; });
  t.mock.method(bridge, "request", async (capability, target) => {
    calls.push([capability, target]);
    if (calls.length === 1) await acknowledgment;
  });
  let finished = false;
  const opening = bridge.openExtensionPreferences().then(() => { finished = true; });
  await new Promise(setImmediate);
  assert.equal(finished, false);
  release();
  await opening;
  assert.equal(finished, true);

  const command = () => Detail({ actions: ActionPanel({ children: Action({ title: "Preferences", onAction: openCommandPreferences }) }) });
  const result = await render(command, { action: { row: 0, id: 0 }, liveNavigation: true, navigationCloseAllowed: true });
  assert.deepEqual(result, { kind: "action" });
  assert.deepEqual(calls, [["preferences.open", "extension"], ["preferences.open", "command"]]);
});

test("initial preferences access ends before passive input and detached work", async (t) => {
  const bridge = require("./raycast-api.cjs");
  const { List, openCommandPreferences, openExtensionPreferences, render, useEffect } = require("./view-api.cjs");
  const calls = [];
  t.mock.method(bridge, "request", async (capability, target) => calls.push([capability, target]));
  let detached;
  let finishMount;
  const mountFinished = new Promise((resolve) => { finishMount = resolve; });
  const command = () => {
    useEffect(async () => {
      detached = mountFinished.then(() => assert.rejects(openCommandPreferences(), /requires a selected view action/));
      await openCommandPreferences();
      await openExtensionPreferences();
    });
    return List({ onSearchTextChange: () => assert.rejects(openCommandPreferences(), /requires a selected view action/) });
  };

  await render(command, { query: "", initialPreferencesAllowed: true });
  finishMount();
  await detached;
  await assert.rejects(render(command, { query: "" }), /requires a selected view action/);
  await assert.rejects(render(command, { query: "changed" }), /requires a selected view action/);
  assert.deepEqual(calls, [["preferences.open", "command"], ["preferences.open", "extension"]]);
});
