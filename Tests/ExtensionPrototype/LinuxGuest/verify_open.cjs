const assert = require("node:assert/strict");
const test = require("node:test");
const { makeOpen, openActionComponents, openActionEffect, webURL } = require("./open-api.cjs");

const component = (type) => (props) => ({ type, props });

test("web URLs preserve query and fragment and normalize host names and Unicode", () => {
  assert.equal(webURL("HTTPS://例子.com/下载?q=a%20b#标签"),
    "https://xn--fsqu00a.com/%E4%B8%8B%E8%BD%BD?q=a%20b#%E6%A0%87%E7%AD%BE");
  assert.equal(webURL("http://[::1]:8080/path"), "http://[::1]:8080/path");
  assert.equal(webURL("https://example.com"), "https://example.com/");
});

test("the web URL parser denies non-web targets, credentials and malformed URLs", () => {
  for (const value of [
    "/Users/user/file", "file:///tmp/file", "raycast://extensions/test", "javascript:alert(1)",
    "https:example.com", "https:///example.com", "//example.com", "https://",
    "https://user:secret@example.com", "https://@example.com", "https://example.com\\@another.example",
    "https://example.com/\nheader", "https://example.com/%0D%0Aheader", "https://example.com/%C2%85",
    "https://example.com/%foo", " https://example.com", "https://example.com/\u202e",
    "https://example.com/" + "x".repeat(2048), new URL("https://example.com"),
  ]) {
    assert.throws(() => webURL(value), /web URL|HTTP\(S\)/);
  }
});

test("built-in open components preserve titles and resolve only their official target props", () => {
  const { Open, OpenInBrowser } = openActionComponents(component);
  const browser = OpenInBrowser({ url: "https://example.com", onOpen: () => assert.fail("host has not opened URL") });
  assert.equal(browser.props.title, "Open in Browser");
  assert.equal(browser.props.icon, "globe-01-16");
  assert.deepEqual(openActionEffect(browser), { kind: "openURL", text: "https://example.com/" });
  const generic = Open({ title: "Docs", target: "https://example.com/docs" });
  assert.equal(generic.props.title, "Docs");
  assert.equal(generic.props.icon, "finder-16");
  assert.equal(OpenInBrowser({ url: "https://example.com", icon: "book-16" }).props.icon, "book-16");
  assert.deepEqual(openActionEffect(generic), { kind: "openURL", text: "https://example.com/docs" });
  assert.throws(() => openActionEffect(OpenInBrowser({ target: "https://example.com" })), /Invalid web URL/);
  assert.deepEqual(openActionEffect(Open({ target: "https://example.com", application: "Safari" })),
    { kind: "openURL", text: "https://example.com/", application: { name: "Safari" } });
});

test("open emits bounded file or URL effects and preserves a denied user-action gate", async () => {
  const intents = [];
  const open = makeOpen((effect) => intents.push(effect));
  await open("https://example.com");
  await open("file:///tmp/Folder%20Name", { path: "/Applications/Editor.app", bundleId: "example.editor" });
  assert.deepEqual(JSON.parse(JSON.stringify(intents)), [
    { kind: "openURL", text: "https://example.com/" },
    { kind: "openFile", paths: ["/tmp/Folder Name"], application: { path: "/Applications/Editor.app", bundleId: "example.editor" } },
  ]);
  await assert.rejects(open("file:///tmp/%2e%2e/private"), /Invalid local file URL/);
  await assert.rejects(open("file:relative"), /Invalid local file URL/);
  await assert.rejects(open("file://external/tmp/private"), /Invalid local file URL/);
  await assert.rejects(open("~/../private"), /absolute file path/);
  await assert.rejects(open("https://example.com", {}), /Invalid application selector/);
  const denied = makeOpen(() => { throw new Error("Open requires a user action"); });
  await assert.rejects(denied("https://example.com"), /requires a user action/);
  assert.equal(intents.length, 2);
  await open("~/Documents/文件.pdf", "Preview.app");
  assert.deepEqual(intents[2], { kind: "openFile", paths: ["~/Documents/文件.pdf"], application: { name: "Preview.app" } });
});

const { Action, ActionPanel, Detail, List, open, render } = require("./view-api.cjs");
const detailWithActions = (children) => () => Detail({ actions: ActionPanel({ children }) });

test("reviewed detail replays both built-in open actions and an explicitly selected callback", async () => {
  const command = detailWithActions([
    Action.Open({ title: "Docs", target: "https://example.com/文档" }),
    Action.OpenInBrowser({ url: "http://example.com/docs" }),
    Action({ title: "Callback", onAction: async () => { await open("https://example.com/callback"); } }),
  ]);
  const snapshot = await render(command, {});
  assert.deepEqual(snapshot.detail.actions.map(({ title, kind }) => [title, kind]), [
    ["Docs", "open"], ["Open in Browser", "openInBrowser"], ["Callback", "callback"],
  ]);
  const expected = [
    "https://example.com/%E6%96%87%E6%A1%A3",
    "http://example.com/docs",
    "https://example.com/callback",
  ];
  for (const [id, url] of expected.entries()) {
    assert.deepEqual(await render(command, { action: { row: 0, id } }), { kind: "openURL", text: url });
  }
});

test("render and passive search callbacks cannot request an open", async () => {
  let directResult;
  const command = () => {
    directResult = open("https://example.com/render");
    directResult.catch(() => {});
    return Detail({});
  };
  assert.equal((await render(command, {})).kind, "detail");
  await assert.rejects(directResult, /requires a selected view action/);
  await assert.rejects(render(() => List({
    onSearchTextChange: async () => { await open("https://example.com/passive"); },
  }), { query: "synthetic" }), /requires a selected view action/);
});

test("a detached render callback cannot borrow the selected action grant", async () => {
  const command = () => {
    const passive = new Promise((resolve) => {
      setImmediate(() => resolve(open("https://example.com/detached").catch((error) => error)));
    });
    return detailWithActions(Action({ title: "Open", onAction: async () => {
      assert.match((await passive).message, /requires a selected view action/);
      await open("https://example.com/selected");
    } }))();
  };
  assert.deepEqual(await render(command, { action: { row: 0, id: 0 } }),
    { kind: "openURL", text: "https://example.com/selected" });
});

test("an unawaited callback loses the grant when its action settles", async () => {
  let late;
  const command = detailWithActions(Action({ title: "Defer", onAction: () => {
    late = new Promise((resolve) => {
      setImmediate(() => resolve(open("https://example.com/late").catch((error) => error)));
    });
  } }));
  assert.equal((await render(command, { action: { row: 0, id: 0 } })).kind, "action");
  assert.match((await late).message, /requires a selected view action/);
});

test("passive menu rendering cannot request a web open", async () => {
  const { MenuBarExtra, runMenuBar } = require("./view-api.cjs");
  let passive;
  await runMenuBar(() => {
    passive = open("https://example.invalid/menu").catch((error) => error);
    return MenuBarExtra({});
  }, { wallTime: 1 });
  assert.match((await passive).message, /requires a selected view action/);
});

test("open completion selects the same action and provides its original target only after receipt", async () => {
  const targets = [];
  const command = detailWithActions([
    Action.Open({ target: "file:///tmp/Doc%20A.pdf", application: "Preview", onOpen: (target) => targets.push(target) }),
    Action.OpenInBrowser({ url: "https://EXAMPLE.com/docs", onOpen: (target) => targets.push(target) }),
  ]);
  const fileAction = { row: 0, id: 0 };
  const browserAction = { row: 0, id: 1 };
  const file = await render(command, { action: fileAction });
  assert.equal(file.kind, "openFile");
  assert.deepEqual(file.paths, ["/tmp/Doc A.pdf"]);
  assert.equal(file.application.name, "Preview");
  const browser = await render(command, { action: browserAction });
  assert.equal(browser.text, "https://example.com/docs");
  assert.deepEqual(targets, []);
  await assert.rejects(render(command, { action: browserAction, openReceipt: file.openReceipt }), /Invalid open completion receipt/);
  const normalized = detailWithActions([Action.Open({ target: "/tmp/unused" }), Action.OpenInBrowser({
    url: "https://example.com/docs", onOpen: () => assert.fail("receipt must retain the original target spelling"),
  })]);
  await assert.rejects(render(normalized, { action: browserAction, openReceipt: browser.openReceipt }), /Invalid open completion receipt/);
  await assert.rejects(render(detailWithActions(Action({ title: "Unrelated" })), {
    action: fileAction, openReceipt: file.openReceipt,
  }), /Invalid open completion receipt/);
  assert.deepEqual(await render(command, { action: fileAction, openReceipt: file.openReceipt }), { kind: "action" });
  assert.deepEqual(await render(command, { action: browserAction, openReceipt: browser.openReceipt }), { kind: "action" });
  assert.deepEqual(targets, ["file:///tmp/Doc%20A.pdf", "https://EXAMPLE.com/docs"]);
});

test("signed view and menu actions wait for the native open reply", async (t) => {
  const broker = require("./raycast-api.cjs");
  const { MenuBarExtra, runMenuBar } = require("./view-api.cjs");
  let ack;
  const receipt = new Promise((resolve) => { ack = resolve; });
  const requests = [];
  const bridge = t.mock.method(broker, "request", async (capability, payload) => {
    requests.push([capability, JSON.parse(payload)]);
    await receipt;
  });
  let resumed = false;
  const command = detailWithActions(Action({ title: "Open file", async onAction() {
    await open("/tmp/some file.txt", "com.apple.TextEdit");
    resumed = true;
  } }));
  const opening = render(command, {
    action: { row: 0, id: 0 }, liveNavigation: true, openTargetAllowed: true,
  });
  await new Promise(setImmediate);
  assert.deepEqual(requests, [["files.open", { path: "/tmp/some file.txt", application: { name: "com.apple.TextEdit" } }]]);
  assert.equal(resumed, false);
  ack();
  assert.deepEqual(await opening, { kind: "action" });
  assert.equal(resumed, true);
  const menu = () => MenuBarExtra({ children: MenuBarExtra.Item({
    title: "Open web", onAction: () => open("https://example.invalid", "com.apple.Safari"),
  }) });
  const selection = { wallTime: 1, openTargetAllowed: true, menuAction: 0 };
  assert.deepEqual(await runMenuBar(menu, selection), { kind: "menuAction" });
  assert.deepEqual(requests.at(-1), ["files.open", {
    url: "https://example.invalid/", application: { name: "com.apple.Safari" },
  }]);
  bridge.mock.mockImplementation(async () => { throw new Error("Host action failed"); });
  await assert.rejects(runMenuBar(menu, selection), /Host action failed/);
});

test("no-view adapters propagate the same open receipt and rejection", async (t) => {
  const broker = require("./raycast-api.cjs");
  const { runCommand, showHUD } = require("./view-api.cjs");
  const calls = [];
  const bridge = t.mock.method(broker, "request", async (capability, payload) => {
    calls.push([capability, JSON.parse(payload)]);
    if (calls.length === 2) throw new Error("Host action failed");
  });
  assert.equal(await broker.open("/tmp/fixture.txt", "TextEdit"), undefined);
  await assert.rejects(broker.open("https://example.invalid/"), /Host action failed/);
  const command = async () => {
    await open("file:///tmp/fixture.txt");
    await showHUD("Opened");
  };
  await assert.rejects(runCommand(command, { mode: "generateV5" }), /requires a selected view action/);
  assert.equal((await runCommand(command, {
    mode: "generateV5", suitePreferencesAllowed: true, openTargetAllowed: true,
  })).kind, "action");
  const history = detailWithActions(Action({ title: "Open", onAction: () => open("/tmp/history.txt") }));
  assert.deepEqual(await render(history, {
    mode: "history", action: { row: 0, id: 0 }, suitePreferencesAllowed: true, openTargetAllowed: true,
  }), { kind: "action" });
  assert.deepEqual(calls, [
    ["files.open", { path: "/tmp/fixture.txt", application: { name: "TextEdit" } }],
    ["files.open", { url: "https://example.invalid/" }],
    ["files.open", { path: "/tmp/fixture.txt" }],
    ["feedback.hud", { text: "Opened", clearRootSearch: false, popToRootType: "default" }],
    ["files.open", { path: "/tmp/history.txt" }],
  ]);
  assert.equal(bridge.mock.callCount(), 5);
});

test("generic open supports validated mail and telephone links across the broker", async (t) => {
  const broker = require("./raycast-api.cjs");
  const events = [];
  t.mock.method(broker, "request", async (capability, payload) => { events.push([capability, JSON.parse(payload)]); });
  const mail = "mailto:fixture@example.invalid?subject=%E6%B5%8B%E8%AF%95";
  const tel = "TEL:+1-(202)-555.0123";
  await broker.open(mail, "com.apple.mail");
  await broker.open(tel);
  assert.deepEqual(events, [
    ["files.open", { url: mail, application: { name: "com.apple.mail" } }],
    ["files.open", { url: "tel:+12025550123" }],
  ]);
  assert.equal(openActionEffect(Action.Open({ target: tel })).text, "tel:+12025550123");
  for (const target of [
    "mailto:fixture@example.invalid?subject=x%0D%0Abcc%3Ay",
    "mailto:fixture@example.invalid?attachment=/etc/hosts", "tel:+12025550123;ext=22",
    "javascript:alert(1)", "data:text/html,example", "example://user@host/path",
  ]) {
    await assert.rejects(broker.open(target));
  }
  assert.equal(events.length, 2);
  assert.throws(() => openActionEffect(Action.OpenInBrowser({ url: mail })), /HTTP/);
});

test("date and completion receipts allow open to wait without file or navigation grants", async (t) => {
  const broker = require("./raycast-api.cjs");
  const calls = [];
  let ready;
  const receipt = new Promise((resolve) => { ready = resolve; });
  t.mock.method(broker, "request", async (capability, payload) => {
    calls.push([capability, JSON.parse(payload)]);
    await receipt;
  });
  const action = { row: 0, id: 0 };
  let resumed = false;
  const date = detailWithActions(Action.PickDate({
    title: "Choose", async onChange() {
      await open("/tmp/date.txt");
      resumed = true;
    },
  }));
  const { dateReceipt } = await render(date, { action });
  const completed = render(date, {
    action, dateReceipt, pickedDate: "2026-11-12T12:34:56.000Z", openTargetAllowed: true,
  });
  await new Promise(setImmediate);
  assert.deepEqual(calls, [["files.open", { path: "/tmp/date.txt" }]]);
  assert.equal(resumed, false);
  ready();
  assert.equal((await completed).kind, "detail");
  assert.equal(resumed, true);

  const firstOpen = detailWithActions(Action.Open({
    target: "/tmp/first.txt", onOpen: () => open("/tmp/next.txt"),
  }));
  const { openReceipt } = await render(firstOpen, { action });
  assert.deepEqual(await render(firstOpen, { action, openReceipt, openTargetAllowed: true }), { kind: "action" });
  assert.deepEqual(calls.at(-1), ["files.open", { path: "/tmp/next.txt" }]);

  const copy = detailWithActions(Action.CopyToClipboard({
    content: "demo", onCopy: () => open("/tmp/copied.txt"),
  }));
  const { copyReceipt } = await render(copy, { action });
  assert.ok(copyReceipt);
  assert.deepEqual(await render(copy, { action, copyReceipt, openTargetAllowed: true }), { kind: "action" });
  assert.deepEqual(calls.at(-1), ["files.open", { path: "/tmp/copied.txt" }]);
});

test("registered-scheme candidates preserve their URL and reject active content and ambiguous escaping", async () => {
  const effects = [];
  const open = makeOpen((effect) => effects.push(effect));
  await open("keylane-test://example/a?tab=2#next", "Example");
  await open("x-apple.systempreferences:com.apple.preference.general");
  assert.deepEqual(effects, [
    { kind: "openURL", text: "keylane-test://example/a?tab=2#next", application: { name: "Example" } },
    { kind: "openURL", text: "x-apple.systempreferences:com.apple.preference.general" },
  ]);
  for (const target of ["keylane-test:", "keylane-test://user:secret@example/path",
    "keylane-test:/%0D%0A", "keylane-test:bad%", "view-source:https://example.invalid", "about:blank",
    "https:example.invalid", "mailto:test@example.invalid?attach=x"]) {
    await assert.rejects(open(target));
  }
  assert.equal(effects.length, 2);
});

test("signed menu actions open resolved local documents and preserve custom-action receipts", async (t) => {
  const broker = require("./raycast-api.cjs");
  const { resolve } = require("node:path");
  const { MenuBarExtra, runMenuBar } = require("./view-api.cjs");
  const calls = [];
  t.mock.method(broker, "request", async (capability, payload) => { calls.push([capability, JSON.parse(payload)]); });
  const menu = () => MenuBarExtra({ children: MenuBarExtra.Item({
    title: "Local", onAction: () => open("./notes/../fixture.txt", "TextEdit"),
  }) });
  await assert.rejects(runMenuBar(menu, { wallTime: 1, menuAction: 0 }), /only open URLs/);
  assert.deepEqual(await runMenuBar(menu, {
    wallTime: 1, menuAction: 0, openTargetAllowed: true,
  }), { kind: "menuAction" });
  assert.deepEqual(calls, [["files.open", {
    path: resolve("fixture.txt"), application: { name: "TextEdit" },
  }]]);
  const local = Action.Open({ target: "./fixture.txt" });
  assert.deepEqual(openActionEffect(local).paths, [resolve("fixture.txt")]);

  const url = "keylane-synthetic://fixture/path";
  let opened;
  const command = detailWithActions(Action.Open({ target: url, onOpen: (original) => { opened = original; } }));
  const action = { row: 0, id: 0 };
  const proposal = await render(command, { action });
  assert.equal(proposal.text, url);
  assert.equal(opened, undefined);
  await render(command, { action, openReceipt: proposal.openReceipt });
  assert.equal(opened, url);
});
