const assert = require("node:assert/strict");
const test = require("node:test");
const {
  Action, ActionPanel, CopyToClipboardAction, Detail, OpenAction, OpenInBrowserAction, render,
} = require("./view-api.cjs");

const withActions = (children) => () => Detail({ actions: ActionPanel({ children }) });
const selection = (id) => ({ action: { row: 0, id } });

test("deprecated built-in actions export the same components as the current Action API", () => {
  assert.equal(CopyToClipboardAction, Action.CopyToClipboard);
  assert.equal(OpenAction, Action.Open);
  assert.equal(OpenInBrowserAction, Action.OpenInBrowser);
});

test("deprecated built-in actions only emit their effects when explicitly selected", async () => {
  const command = withActions([
    CopyToClipboardAction({ content: "已复制" }),
    OpenAction({ title: "Open documentation", target: "https://example.com/文档" }),
    OpenInBrowserAction({ url: "https://example.com" }),
  ]);
  const snapshot = await render(command, {});
  assert.equal(snapshot.kind, "detail");
  assert.deepEqual(snapshot.detail.actions.map(({ kind, title }) => [kind, title]), [
    ["copy", "Copy to Clipboard"], ["open", "Open documentation"], ["openInBrowser", "Open in Browser"],
  ]);
  assert.deepEqual(await render(command, selection(0)), { kind: "copy", text: "已复制" });
  assert.deepEqual(await render(command, selection(1)), {
    kind: "openURL", text: "https://example.com/%E6%96%87%E6%A1%A3",
  });
  assert.deepEqual(await render(command, selection(2)), { kind: "openURL", text: "https://example.com/" });
});

test("deprecated built-in actions keep the existing URL and clipboard boundaries", async () => {
  const command = withActions([
    CopyToClipboardAction({ content: { file: "/tmp/synthetic" } }),
    OpenAction({ target: "https://example.com", application: "Safari" }),
    OpenInBrowserAction({ url: "file:///tmp/synthetic" }),
  ]);
  assert.deepEqual(await render(command, selection(0)), {
    kind: "copy", clipboardContent: { file: "/tmp/synthetic" },
  });
  assert.deepEqual(await render(command, selection(1)), {
    kind: "openURL", text: "https://example.com/", application: { name: "Safari" },
  });
  await assert.rejects(render(command, selection(2)), /Expected an HTTP\(S\) URL/);
});
