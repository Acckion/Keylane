const assert = require("node:assert/strict");
const test = require("node:test");
const api = require("./view-api.cjs");
const { FormValidation, utilitiesFor } = require("./raycast-utils.cjs");
const { Action, ActionPanel, Detail, Form, List, render } = api;
const { useForm, useLocalStorage, usePromise } = utilitiesFor(() => api);
const submit = { row: 0, id: 0 };

test("useForm binds initial values and refuses required or custom-invalid submissions", async () => {
  const submissions = [];
  const command = () => {
    const form = useForm({
      initialValues: { name: "初始", flag: true },
      validation: { name: FormValidation.Required, flag: (value) => value ? undefined : "Check this box" },
      onSubmit: (values) => { submissions.push(values); },
    });
    return Form({
      children: [
        Form.TextField({ title: "Name", ...form.itemProps.name }),
        Form.Checkbox({ label: "Confirm", ...form.itemProps.flag }),
        Form.TextArea({ title: "Note", ...form.itemProps.note }),
      ],
      actions: ActionPanel({ children: Action.SubmitForm({ title: "Submit", onSubmit: form.handleSubmit }) }),
    });
  };
  const reply = await render(command, {});
  assert.equal(reply.kind, "form");
  assert.deepEqual(reply.form.fields.map(({ id, value }) => [id, value]), [
    ["name", "初始"], ["flag", true], ["note", ""],
  ]);
  for (const [name, flag, message] of [["", true, "The item is required"], ["姓名", false, "Check this box"]]) {
    const rejected = await render(command, { action: submit, formValues: { name, flag, note: "" } });
    assert.equal(rejected.kind, "formRejected");
    assert.equal(rejected.toastStyle, "FAILURE");
    assert.equal(rejected.text, `Form validation failed ${message}`);
    assert.equal(rejected.form.fields.length, 3);
  }
  assert.deepEqual(submissions, []);
  assert.deepEqual(await render(command, { action: submit, formValues: { name: "姓名", flag: true, note: "说明" } }),
    { kind: "action" });
  assert.deepEqual(submissions, [{ name: "姓名", flag: true, note: "说明" }]);
});

test("usePromise waits for guest work, supports disabling and exposes errors", async () => {
  const events = [];
  const command = () => {
    const resolved = usePromise(async (name) => name.toUpperCase(), ["test"], {
      onWillExecute: (args) => events.push(args[0]),
      onData: (data) => events.push(data),
    });
    const failed = usePromise(async () => { throw new Error("bad promise"); }, [], {
      onError: (error) => events.push(error.message),
    });
    usePromise(async () => assert.fail("disabled operation ran"), [], { execute: false });
    return Detail({ markdown: `${resolved.data} / ${failed.error?.message}`,
      isLoading: resolved.isLoading || failed.isLoading });
  };
  const reply = await render(command, {});
  assert.equal(reply.detail.markdown, "TEST / bad promise");
  assert.equal(reply.detail.isLoading, false);
  assert.deepEqual(events, ["test", "TEST", "bad promise"]);
});

test("chained usePromise operations settle across rerenders", async () => {
  const calls = [];
  const command = () => {
    const first = usePromise(async () => {
      calls.push("first");
      return "dependency";
    });
    const second = usePromise(async (value) => {
      calls.push("second:" + value);
      return value.toUpperCase();
    }, [first.data], { execute: first.data !== undefined });
    return Detail({ markdown: second.data, isLoading: second.isLoading });
  };

  const result = await render(command, {});
  assert.equal(result.detail.markdown, "DEPENDENCY");
  assert.equal(result.detail.isLoading, false);
  assert.deepEqual(calls, ["first", "second:dependency"]);
});

test("settling reruns changed dependencies and rejects nonsettling effects", async () => {
  const calls = [];
  const command = () => {
    const [index, setIndex] = api.useState(0);
    api.useEffect(() => calls.push("mount"), []);
    api.useEffect(() => {
      calls.push(index);
      if (index < 2) setIndex(index + 1);
    }, [index]);
    return Detail({ markdown: String(index) });
  };
  assert.equal((await render(command, {})).detail.markdown, "2");
  assert.deepEqual(calls, ["mount", 0, 1, 2]);
  await assert.rejects(render(() => {
    const [index, setIndex] = api.useState(0);
    api.useEffect(() => setIndex(index + 1), [index]);
    return Detail({ markdown: String(index) });
  }, {}), /View effects did not settle/);
});

test("usePromise times out and aborts an unfinished operation", async () => {
  const abortable = {};
  let aborted = false;
  const command = () => {
    const result = usePromise(() => new Promise(() => {
      abortable.current.signal.addEventListener("abort", () => { aborted = true; });
    }), [], { abortable, onError: () => {} });
    return Detail({ markdown: result.error?.message, isLoading: result.isLoading });
  };
  const reply = await render(command, {});
  assert.equal(reply.detail.markdown, "The extension operation timed out.");
  assert.equal(reply.detail.isLoading, false);
  assert.equal(aborted, true);
});

test("useLocalStorage uses the available scope and round-trips structured values", async () => {
  const key = "test-fixture-key";
  const next = { name: "记录", time: new Date("2026-11-12T00:00:00Z"), bytes: Buffer.from([1, 2]) };
  const command = () => {
    const state = useLocalStorage(key, { name: "默认" });
    return List({ children: List.Item({
      title: state.value?.name ?? "empty",
      subtitle: state.value?.time?.toISOString(),
      actions: ActionPanel({ children: [
        Action({ title: "Set", onAction: () => state.setValue(next) }),
        Action({ title: "Remove", onAction: state.removeValue }),
      ] }),
    }) });
  };
  assert.equal((await render(command, { storage: {} })).rows[0].title, "默认");
  const written = await render(command, { storage: {}, action: submit });
  assert.equal(written.kind, "storage");
  assert.match(written.storage[key], /__raycast_cached_buffer__/);
  const loaded = await render(command, { storage: written.storage });
  assert.equal(loaded.rows[0].title, "记录");
  assert.equal(loaded.rows[0].subtitle, "2026-11-12T00:00:00.000Z");
  const removed = await render(command, { storage: written.storage, action: { ...submit, id: 1 } });
  assert.equal(removed.kind, "storage");
  assert.equal(Object.hasOwn(removed.storage, key), false);
  const failure = await render(command, { action: submit });
  assert.equal(failure.kind, "toast");
  assert.equal(failure.toastStyle, "FAILURE");
  assert.equal(failure.text, "Failed to set value in local storage LocalStorage unavailable");
  assert.equal(failure.feedbackAction.kind, "copyLogs");
  assert.match(failure.feedbackAction.value, /^Error: LocalStorage unavailable/);
});

test("usePromise mutations respect rollback and the revalidation option", async () => {
  let executions = 0;
  const command = () => {
    const result = usePromise(async () => ({ count: ++executions }));
    return Detail({ actions: ActionPanel({ children: Action({ title: "Mutate", onAction: async () => {
      await assert.rejects(result.mutate(Promise.reject(new Error("failed update")), {
        optimisticUpdate: (data) => { data.count = 50; return data; },
        shouldRevalidateAfter: false,
      }), /failed update/);
      await result.mutate(undefined, {
        optimisticUpdate(data) { assert.equal(data.count, 1); return data; },
        shouldRevalidateAfter: false,
      });
      assert.equal(executions, 1);
      assert.equal(await result.mutate(Promise.resolve("updated")), "updated");
      assert.equal(executions, 2);
    } }) }) });
  };
  assert.deepEqual(await render(command, { action: submit }), { kind: "action" });
});

test("useLocalStorage preserves the old value during writes and clears it during removal", async () => {
  const slots = [];
  let index = 0;
  let effect;
  let saved;
  let pending;
  const hooks = utilitiesFor(() => ({
    useState(initial) {
      const position = index++;
      if (!(position in slots)) slots[position] = initial();
      return [slots[position]];
    },
    useEffect(callback) { effect = callback; },
    LocalStorage: {
      async getItem() { return saved; },
      setItem(_key, value) {
        return new Promise((resolve) => {
          pending = () => { saved = value; resolve(); };
        });
      },
      removeItem() {
        return new Promise((resolve) => {
          pending = () => { saved = undefined; resolve(); };
        });
      },
    },
  }));
  function renderStorage() {
    index = 0;
    return hooks.useLocalStorage("fixture", "default");
  }

  const initial = renderStorage();
  assert.equal(initial.isLoading, true);
  assert.equal(initial.value, undefined);
  await effect();
  const loaded = renderStorage();
  assert.equal(loaded.value, "default");
  assert.equal(loaded.isLoading, false);

  const writing = loaded.setValue("updated");
  const duringWrite = renderStorage().value;
  pending();
  await writing;
  assert.equal(duringWrite, "default");
  assert.equal(renderStorage().value, "updated");

  const removing = renderStorage().removeValue();
  const duringRemoval = renderStorage().value;
  pending();
  await removing;
  assert.equal(duringRemoval, undefined);
  assert.equal(renderStorage().value, "default");
});

test("usePromise paginates List and Grid with page, cursor and last item", async () => {
  for (const View of [List, api.Grid]) {
    const calls = [];
    const received = [];
    const command = () => {
      const { data, pagination, isLoading } = usePromise((prefix) => async (options) => {
        calls.push(options);
        const { page } = options;
        return { data: [prefix + page], hasMore: page < 2, cursor: "cursor-" + page };
      }, ["第"], { onData: (rows, options) => received.push([rows, options.page]) });
      return View({ pagination, isLoading,
        children: data?.map((title) => View.Item({ title, content: title })),
      });
    };

    const reply = await render(command, { pageCount: 3 });
    assert.deepEqual(reply.pagination, { pageCount: 2, hasMore: false });
    const rows = View === List ? reply.rows : reply.grid.sections.flatMap(({ items }) => items);
    assert.deepEqual(rows.map(({ title }) => title), ["第0", "第1", "第2"]);
    assert.deepEqual(calls, [
      { page: 0 },
      { page: 1, cursor: "cursor-0", lastItem: "第0" },
      { page: 2, cursor: "cursor-1", lastItem: "第1" },
    ]);
    assert.deepEqual(received, [[["第0"], 0], [["第1"], 1], [["第2"], 2]]);
  }
});

test("useLocalStorage publishes updated rows after persisting or removing a value", async (t) => {
  const stored = new Map();
  const broker = require("./raycast-api.cjs");
  t.mock.method(broker, "request", async (capability, text) => {
    assert.equal(capability, "storage.request");
    const { operation, key, value } = JSON.parse(text);
    if (operation === "get") return JSON.stringify({ value: stored.get(key) });
    if (operation === "set") stored.set(key, value);
    else if (operation === "remove") stored.delete(key);
    else assert.fail("unexpected storage request");
    return "";
  });
  const command = () => {
    const { value, setValue, removeValue, isLoading } = useLocalStorage("fixture", { title: "Default" });
    return List({ isLoading, children: List.Item({
      title: value?.title ?? "Loading",
      actions: ActionPanel({ children: [
        Action({ title: "Set", onAction: () => setValue({ title: "Saved" }) }),
        Action({ title: "Remove", onAction: removeValue }),
      ] }),
    }) });
  };
  const input = { localStorageAllowed: true };
  const written = await render(command, { ...input, action: submit });
  assert.equal(written.kind, "view");
  assert.equal(written.storageUpdated, true);
  assert.equal(written.rows[0].title, "Saved");
  assert.equal(written.isLoading, false);
  const removed = await render(command, { ...input, action: { ...submit, id: 1 } });
  assert.equal(removed.kind, "view");
  assert.equal(removed.storageUpdated, true);
  assert.equal(removed.rows[0].title, "Default");
  assert.equal(removed.isLoading, false);
});

test("useLocalStorage ignores an old key's mutation completion after switching keys", async () => {
  const slots = [];
  let index = 0;
  let effect;
  let finishWrite;
  const requests = [];
  const saved = new Map([["a", '"original"'], ["b", '"other"']]);
  const hooks = utilitiesFor(() => ({
    useState(initial) {
      const position = index++;
      if (!(position in slots)) slots[position] = initial();
      return [slots[position]];
    },
    useEffect(callback) { effect = callback; },
    LocalStorage: {
      async getItem(key) { requests.push(key); return saved.get(key); },
      setItem(key, value) {
        return new Promise((resolve) => {
          finishWrite = () => { saved.set(key, value); resolve(); };
        });
      },
    },
  }));
  function renderKey(key) {
    index = 0;
    return hooks.useLocalStorage(key);
  }
  renderKey("a");
  await effect();
  const write = renderKey("a").setValue("changed");
  assert.equal(renderKey("b").isLoading, true);
  await effect();
  assert.equal(renderKey("b").value, "other");
  finishWrite();
  await write;
  assert.equal(renderKey("b").value, "other");
  assert.equal(renderKey("b").isLoading, false);
  assert.deepEqual(requests, ["a", "b"]);
  renderKey("a");
  await effect();
  assert.equal(renderKey("a").value, "changed");
});
