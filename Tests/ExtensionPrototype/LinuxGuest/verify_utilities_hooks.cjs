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
  assert.deepEqual(await render(command, { action: submit, formValues: { name: "", flag: true, note: "" } }),
    { kind: "error", text: "Form validation failed The item is required" });
  assert.deepEqual(await render(command, { action: submit, formValues: { name: "姓名", flag: false, note: "" } }),
    { kind: "error", text: "Form validation failed Check this box" });
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
  assert.deepEqual(await render(command, { action: submit }), {
    kind: "error", text: "Failed to set value in local storage LocalStorage unavailable",
  });
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

test("usePromise settles dependent operations in the same view", async () => {
  const calls = [];
  const command = () => {
    const first = usePromise(async () => { calls.push("first"); return "ready"; }, []);
    const second = usePromise(async (value) => { calls.push("second"); return value.toUpperCase(); },
      [first.data], { execute: first.data !== undefined });
    return Detail({ markdown: second.data, isLoading: first.isLoading || second.isLoading });
  };
  const { detail } = await render(command, {});
  assert.equal(detail.markdown, "READY");
  assert.equal(detail.isLoading, false);
  assert.deepEqual(calls, ["first", "second"]);
});

test("an effect that continuously changes its dependencies stops at the pass limit", async () => {
  const { useState, useEffect } = require("./view-api.cjs");
  let calls = 0;
  const command = () => {
    const [value, setValue] = useState(0);
    useEffect(() => { calls++; setValue(value + 1); }, [value]);
    return Detail({ markdown: String(value) });
  };
  await assert.rejects(render(command, {}), /View effects did not settle/);
  assert.equal(calls, 8);
});

test("List and Grid resolve selection-driven promises within the replay grant", async () => {
  const { Grid, LocalStorage, useState } = api;
  for (const View of [List, Grid]) {
    const calls = [];
    const command = () => {
      const [selected, select] = useState();
      const { data, isLoading } = usePromise(async (item) => {
        calls.push(item);
        await assert.rejects(LocalStorage.setItem("denied", item), /LocalStorage writes are unavailable/);
        return `Details for ${item}`;
      }, [selected], { execute: selected !== undefined });
      return View({ isShowingDetail: true, onSelectionChange: select, isLoading,
        children: ["a", "b"].map((id) => View.Item({
          id, title: data ?? id, content: "📄", detail: List.Item.Detail({ markdown: data }),
        })),
      });
    };
    const result = await render(command, { selectedItemId: "b", selectionEvent: true, storage: {} });
    assert.deepEqual(calls, ["b"]);
    if (View === List) {
      assert.equal(result.rows[1].markdown, "Details for b");
      assert.equal(result.isLoading, false);
    } else {
      assert.equal(result.grid.sections[0].items[1].title, "Details for b");
      assert.equal(result.grid.isLoading, false);
    }
  }
});
