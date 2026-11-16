const assert = require("node:assert/strict");
const { test } = require("node:test");
const { configureEnvironment } = require("./environment.cjs");
const { guestDiagnostics } = require("./diagnostics-api.cjs");
const {
  Action, ActionPanel, captureException, captureMemorySnapshot, Detail, Form, Grid, List,
  render, useActionPanel, useEffect,
} = require("./view-api.cjs");

const copyPanel = (text) => ActionPanel({ children: Action.CopyToClipboard({ title: text, content: text }) });

test("diagnostics are bounded, retain only safe values, and require development mode for memory sampling", () => {
  configureEnvironment({ isDevelopment: false });
  captureMemorySnapshot("test file path");
  assert.deepEqual(guestDiagnostics(), []);
  const exception = { get message() { assert.fail("exception details must not be read"); } };
  captureException(exception);
  configureEnvironment({ isDevelopment: true });
  try {
    captureMemorySnapshot("another private file path");
    const [exceptionRecord, memoryRecord] = guestDiagnostics();
    assert.deepEqual(exceptionRecord, { kind: "exception", valueType: "object" });
    assert.deepEqual(Object.keys(memoryRecord), ["kind", "heapUsed", "heapTotal"]);
    assert.equal(memoryRecord.kind, "memory");
    assert.ok(memoryRecord.heapUsed > 0 && memoryRecord.heapTotal >= memoryRecord.heapUsed);
    for (let count = 0; count < 100; count++) captureException("private data");
    assert.equal(guestDiagnostics().length, 16);
    assert.doesNotMatch(JSON.stringify(guestDiagnostics()), /private|file path/);
  } finally {
    configureEnvironment(undefined);
  }
});

test("useActionPanel updates the view and reconstructs the same selected action", async () => {
  function command() {
    const panel = useActionPanel();
    useEffect(() => panel.update(copyPanel("updated")));
    return Detail({ actions: copyPanel("original") });
  }
  const view = await render(command, {});
  assert.equal(view.detail.actions[0].title, "updated");
  assert.deepEqual(await render(command, { action: { row: 0, id: 0 } }), { kind: "copy", text: "updated" });
});

test("useActionPanel uses the same override for List, Grid and empty panels", async () => {
  const commandFor = (view) => () => {
    useActionPanel().update(copyPanel("override"));
    return view;
  };
  const list = commandFor(List({ children: List.Item({ title: "One" }) }));
  assert.equal((await render(list, {})).rows[0].actions[0].title, "override");
  assert.deepEqual(await render(list, { action: { row: 0, id: 0 } }), { kind: "copy", text: "override" });
  await assert.rejects(render(list, { action: { row: 1, id: 0 } }), /Unknown action/);
  assert.equal((await render(list, { query: "missing" })).empty.actions[0].title, "override");

  const grid = commandFor(Grid({ children: Grid.Item({ title: "One" }) }));
  assert.equal((await render(grid, {})).grid.sections[0].items[0].actions[0].title, "override");
  assert.deepEqual(await render(grid, { action: { row: 0, id: 0 } }), { kind: "copy", text: "override" });
  assert.equal((await render(grid, { query: "missing" })).grid.actions[0].title, "override");
});

test("useActionPanel preserves Form submit validation", async () => {
  let submitted;
  function command() {
    useActionPanel().update(ActionPanel({
      children: Action.SubmitForm({ title: "Save", onSubmit: (values) => { submitted = values; } }),
    }));
    return Form({ children: Form.TextField({ id: "title" }) });
  }
  assert.equal((await render(command, {})).formActions[0].title, "Save");
  const action = { row: 0, id: 0 };
  assert.deepEqual(await render(command, { action, formValues: { title: "示例" } }), { kind: "action" });
  assert.deepEqual(submitted, { title: "示例" });
  await assert.rejects(render(command, { action, formValues: { title: 100 } }), /Invalid Form field value/);
});

test("useActionPanel clears declared actions and rejects updates after the render ends", async () => {
  let escaped;
  const command = () => {
    escaped = useActionPanel();
    escaped.update(null);
    return Detail({ actions: copyPanel("original") });
  };
  assert.deepEqual((await render(command, {})).detail.actions, []);
  assert.throws(() => escaped.update(copyPanel("stale")), /active view render/);
  await assert.rejects(render(command, { action: { row: 0, id: 0 } }), /Unknown action/);
  assert.equal((await render(() => Detail({ actions: copyPanel("next") }), {})).detail.actions[0].title, "next");
});

test("action-panel overrides participate in valid navigation routes and preserve invalid-row rejection", async () => {
  const command = () => {
    useActionPanel().update(ActionPanel({
      children: Action.Push({ title: "Details", target: Detail({ markdown: "next" }) }),
    }));
    return List({ children: List.Item({ title: "One" }) });
  };
  assert.equal((await render(command, { action: { row: 0, id: 0 } })).kind, "pushView");
  const viewRoute = [{ query: "", row: 0, id: 0, mode: "action" }];
  assert.equal((await render(command, { viewRoute })).detail.markdown, "next");
  await assert.rejects(render(command, { viewRoute: [{ ...viewRoute[0], row: 1 }] }), /Unknown view route/);
});
