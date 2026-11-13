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

test("the no-view adapter and menu actions cannot request a web open", async () => {
  assert.equal(require("./raycast-api.cjs").open, undefined);
  const { MenuBarExtra, runMenuBar } = require("./view-api.cjs");
  const menu = () => MenuBarExtra({ children: MenuBarExtra.Item({
    title: "Open",
    onAction: async () => { await open("https://example.com/menu"); },
  }) });
  await assert.rejects(runMenuBar(menu, { menuAction: 0, wallTime: 1 }), /requires a selected view action/);
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
