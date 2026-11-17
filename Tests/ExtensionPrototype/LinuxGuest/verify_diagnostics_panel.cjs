const assert = require("node:assert/strict");
const { test } = require("node:test");
const { configureExceptionReporting, configureMemoryReporting, guestDiagnostics, recordMemorySample } = require("./diagnostics-api.cjs");
const {
  Action, ActionPanel, captureException, captureMemorySnapshot, Detail, Form, Grid, List,
  render, useActionPanel, useEffect,
} = require("./view-api.cjs");

const copyPanel = (text) => ActionPanel({ children: Action.CopyToClipboard({ title: text, content: text }) });

test("exception diagnostics retain only value categories", () => {
  const sent = [];
  configureExceptionReporting((type) => { sent.push(type); });
  try {
    const exception = { get message() { assert.fail("exception details must not be read"); } };
    assert.equal(captureException(exception), undefined);
    captureException(new Error("private message"));
    captureException(new Proxy({}, { get() { assert.fail("exception properties must not be read"); } }));
    assert.deepEqual(sent, ["object", "error", "object"]);
    assert.deepEqual(guestDiagnostics().map(({ valueType }) => valueType), sent);
    for (let count = 0; count < 100; count++) captureException("private data");
    assert.equal(guestDiagnostics().length, 16);
    assert.equal(sent.length, 16);
    assert.doesNotMatch(JSON.stringify(sent), /private/);
  } finally {
    configureExceptionReporting(undefined);
  }
});

test("memory diagnostics require an explicit reporter and send bounded labeled and automatic samples immediately", () => {
  const samples = [];
  captureMemorySnapshot("disabled");
  configureMemoryReporting((sample) => { samples.push(sample); });
  try {
    captureMemorySnapshot("After\nparsing");
    recordMemorySample(null);
    assert.deepEqual(samples.map(({ label }) => label), ["After parsing", null]);
    assert.ok(samples.every(({ heapUsed, heapTotal }) => heapUsed > 0 && heapTotal >= heapUsed));
    captureMemorySnapshot("标题".repeat(96));
    assert.equal(samples[2].label.length, 96);
    for (let count = 0; count < 100; count++) captureMemorySnapshot("repeat");
    assert.equal(samples.length, 16);
  } finally {
    configureMemoryReporting(undefined);
  }
  captureMemorySnapshot("disabled again");
  assert.equal(samples.length, 16);
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

test("useActionPanel changes publish during a pending effect even when view state is unchanged", async () => {
  const sleep = require("node:timers/promises").setTimeout;
  const observed = [];
  const command = () => {
    const panel = useActionPanel();
    useEffect(async () => {
      panel.update(copyPanel("first update"));
      await sleep(170);
      panel.update(copyPanel("second update"));
      await sleep(170);
      panel.update(null);
    });
    return Detail({ markdown: "unchanged", actions: copyPanel("original"), isLoading: true });
  };
  const result = await render(command, {}, {
    publish(preview) { observed.push(preview.detail.actions.map(({ title }) => title)); },
  });
  assert.deepEqual(observed, [["first update"], ["second update"]]);
  assert.deepEqual(result.detail.actions, []);
});
