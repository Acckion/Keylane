const assert = require("node:assert/strict");
const { test } = require("node:test");
const { makeToastAdapter } = require("./toast.cjs");

test("Toast construction is inert and showToast returns a shown instance", async () => {
  const events = [];
  const { Toast, ToastStyle, showToast } = makeToastAdapter({
    show: (toast, options) => events.push({ operation: "show", toast, options }),
    hide: (toast) => events.push({ operation: "hide", toast }),
  });
  assert.equal(Toast.Style, ToastStyle);
  const original = new Toast({ title: "原始", message: "详情" });
  assert.deepEqual(events, []);
  assert.equal(await original.hide(), undefined);
  assert.deepEqual(events, []);

  const toast = await showToast(Toast.Style.Failure, "错误", "详情");
  assert.ok(toast instanceof Toast);
  assert.deepEqual(events, [{
    operation: "show", toast, options: { style: Toast.Style.Failure, title: "错误", message: "详情" },
  }]);
  assert.equal(await toast.hide(), undefined);
  await toast.hide();
  assert.deepEqual(events[1], { operation: "hide", toast });
  assert.equal(events.length, 2);

  assert.equal(await original.show(), undefined);
  assert.deepEqual(events[2], {
    operation: "show", toast: original, options: { style: Toast.Style.Success, title: "原始", message: "详情" },
  });
});

test("a queued hide follows show and a failed show can be retried", async () => {
  const events = [];
  let attempt = 0;
  const { Toast } = makeToastAdapter({
    show: async () => {
      events.push("show");
      if (++attempt === 1) throw new Error("feedback unavailable");
    },
    hide: () => events.push("hide"),
  });
  const toast = new Toast({ title: "Example" });
  await assert.rejects(toast.show(), /feedback unavailable/);
  await toast.hide();
  await Promise.all([toast.show(), toast.hide()]);
  assert.deepEqual(events, ["show", "show", "hide"]);
});

test("invalid or oversized toast text is rejected before feedback can be sent", () => {
  const fail = () => assert.fail("invalid options must not reach the adapter");
  const { Toast } = makeToastAdapter({ show: fail, hide: fail });
  assert.throws(() => new Toast({ title: false }), /Invalid toast/);
  assert.throws(() => new Toast({ title: "Title", style: "invented" }), /Invalid toast/);
  assert.throws(() => new Toast({ title: "中".repeat(683) }), /feedback limit/);
});

test("reviewed view callbacks emit the latest visible toast and can withdraw it", async () => {
  const { Action, ActionPanel, List, Toast, render, showToast } = require("./view-api.cjs");
  const command = (onAction) => () => List({ children: List.Item({
    title: "Fixture", actions: ActionPanel({ children: Action({ onAction }) }),
  }) });
  const input = { action: { row: 0, id: 0 } };

  const shown = await render(command(async () => {
    const old = await showToast({ title: "Old", style: Toast.Style.Failure });
    const next = new Toast({ title: "Ready", message: "完成" });
    await next.show();
    await old.hide();
  }), input);
  assert.deepEqual(shown, { kind: "toast", text: "Ready 完成", toastStyle: Toast.Style.Success });

  const hidden = await render(command(async () => {
    const toast = new Toast({ title: "Temporary", style: Toast.Style.Failure });
    await toast.show();
    await toast.hide();
  }), input);
  assert.deepEqual(hidden, { kind: "action" });
});

test("Toast fields read and mutate with validation, including clearing the message", () => {
  const fail = () => assert.fail("hidden changes must not reach the feedback adapter");
  const { Toast } = makeToastAdapter({ show: fail, hide: fail, update: fail });
  const toast = new Toast({ title: "Start", message: "Working" });
  assert.equal(toast.title, "Start");
  assert.equal(toast.message, "Working");
  assert.equal(toast.style, Toast.Style.Success);

  toast.title = "完成";
  toast.message = undefined;
  toast.style = Toast.Style.Animated;
  assert.equal(toast.title, "完成");
  assert.equal(toast.message, undefined);
  assert.equal(toast.style, Toast.Style.Animated);

  assert.throws(() => { toast.style = "invented"; }, /Invalid toast options/);
  assert.throws(() => { toast.title = null; }, /Invalid toast options/);
  assert.throws(() => { toast.message = "中".repeat(681); }, /feedback limit/);
  assert.equal(toast.title, "完成");
  assert.equal(toast.message, undefined);
  assert.equal(toast.style, Toast.Style.Animated);
});

test("Toast field snapshots are ordered with show and hide", async () => {
  const events = [];
  const { Toast, flushToastUpdates } = makeToastAdapter({
    show: (_toast, options) => events.push({ type: "show", options }),
    update: (_toast, options) => events.push({ type: "update", options }),
    hide: () => events.push({ type: "hide" }),
  });
  const toast = new Toast({ title: "Before", style: Toast.Style.Animated });
  toast.message = "Waiting";
  const shown = toast.show();
  toast.title = "Done";
  toast.message = undefined;
  toast.style = Toast.Style.Success;
  toast.style = Toast.Style.Success;
  const hidden = toast.hide();
  toast.title = "Hidden";
  await flushToastUpdates();
  await Promise.all([shown, hidden]);

  assert.deepEqual(events, [
    { type: "show", options: { title: "Before", message: "Waiting", style: Toast.Style.Animated } },
    { type: "update", options: { title: "Done", message: "Waiting", style: Toast.Style.Animated } },
    { type: "update", options: { title: "Done", message: undefined, style: Toast.Style.Animated } },
    { type: "update", options: { title: "Done", message: undefined, style: Toast.Style.Success } },
    { type: "hide" },
  ]);
  await toast.show();
  assert.deepEqual(events.at(-1), {
    type: "show", options: { title: "Hidden", message: undefined, style: Toast.Style.Success },
  });
});

test("a rejected Toast update does not block subsequent field or lifecycle operations", async () => {
  const events = [];
  const { Toast, flushToastUpdates } = makeToastAdapter({
    show: () => events.push("show"),
    update: (_toast, { title }) => {
      events.push(title);
      if (title === "Retry") throw new Error("feedback unavailable");
    },
    hide: () => events.push("hide"),
  });
  const toast = new Toast({ title: "Start" });
  await toast.show();
  toast.title = "Retry";
  toast.title = "Recovered";
  await flushToastUpdates();
  await toast.hide();
  assert.deepEqual(events, ["show", "Retry", "Recovered", "hide"]);
});

test("selected view actions emit the mutated fields of the visible toast", async () => {
  const { Action, ActionPanel, List, Toast, render, showToast } = require("./view-api.cjs");
  const command = () => List({ children: List.Item({
    title: "Fixture",
    actions: ActionPanel({ children: Action({ onAction: async () => {
      const toast = await showToast({ title: "Progress", style: Toast.Style.Animated });
      toast.title = "完成";
      toast.style = Toast.Style.Success;
      toast.message = "详情";
    } }) }),
  }) });
  const reply = await render(command, { action: { row: 0, id: 0 } });
  assert.deepEqual(reply, { kind: "toast", text: "完成 详情", toastStyle: Toast.Style.Success });
});

test("mutating a superseded toast preserves feedback owned by the newer toast", async () => {
  const { Action, ActionPanel, List, Toast, render, showToast } = require("./view-api.cjs");
  const command = () => List({ children: List.Item({
    title: "Fixture",
    actions: ActionPanel({ children: Action({ onAction: async () => {
      const old = await showToast({ title: "Old" });
      await showToast({ title: "Current" });
      old.title = "Stale";
      old.style = Toast.Style.Failure;
    } }) }),
  }) });
  const reply = await render(command, { action: { row: 0, id: 0 } });
  assert.deepEqual(reply, { kind: "toast", text: "Current", toastStyle: Toast.Style.Success });
});

test("live view Toast sends only selected callback events and avoids duplicate final feedback", async (t) => {
  const api = require("./view-api.cjs");
  const broker = require("./raycast-api.cjs");
  const requests = [];
  t.mock.method(broker, "request", async (capability, text) => {
    assert.equal(capability, "feedback.toast");
    requests.push(JSON.parse(text));
  });
  const command = () => api.List({
    onSearchTextChange: () => api.showToast({ title: "Search replay" }),
    children: api.List.Item({ title: "Task", actions: api.ActionPanel({ children: api.Action({
      title: "Run", async onAction() {
        const toast = await api.showToast({ title: "Working", style: api.Toast.Style.Animated });
        toast.title = "Done";
        await toast.hide();
        await api.showToast({ title: "Finished" });
      },
    }) }) }),
  });
  assert.deepEqual(await api.render(command, { query: "Task", liveToast: true, action: { row: 0, id: 0 } }), { kind: "action" });
  assert.deepEqual(requests.map(({ operation, title }) => [operation, title]), [
    ["show", "Working"], ["update", "Done"], ["hide", undefined], ["show", "Finished"],
  ]);
  assert.equal(requests[0].id, requests[2].id);
  assert.notEqual(requests[0].id, requests[3].id);
  requests.length = 0;
  const form = () => api.Form({
    children: api.Form.PasswordField({ id: "secret" }),
    actions: api.ActionPanel({ children: api.Action.SubmitForm({
      onSubmit: ({ secret }) => api.showToast({ title: secret, style: api.Toast.Style.Failure }),
    }) }),
  });
  assert.deepEqual(await api.render(form, {
    liveToast: true, sensitiveFormSubmission: true, action: { row: 0, id: 0 }, formValues: { secret: "synthetic" },
  }), { kind: "error" });
  assert.deepEqual(requests, []);
});

test("toast action assignment snapshots live primary and secondary slots without serializing callbacks", async () => {
  const { registerNativeToastAction } = require("./toast.cjs");
  const presentations = [];
  const { Toast, flushToastUpdates } = makeToastAdapter({
    show: (_toast, options) => presentations.push(options),
    update: (_toast, options) => presentations.push(options),
  });
  const primary = registerNativeToastAction({ title: "First", onAction() {} }, { kind: "copyLogs", value: "first" });
  const secondary = registerNativeToastAction({ title: "Second", onAction() {} }, { kind: "copyLogs", value: "second" });
  const custom = { title: "Retry", onAction() {} };
  const toast = new Toast({ title: "Report", primaryAction: primary, secondaryAction: secondary });
  assert.equal(toast.primaryAction, primary);
  assert.equal(toast.secondaryAction, secondary);
  await toast.show();
  toast.primaryAction = custom;
  toast.secondaryAction = undefined;
  assert.equal(toast.primaryAction, custom);
  assert.equal(toast.secondaryAction, undefined);
  assert.throws(() => { toast.primaryAction = { title: "Malformed" }; }, /Invalid toast action/);
  assert.equal(toast.primaryAction, custom);
  await flushToastUpdates();
  assert.deepEqual(presentations.map(({ feedbackAction, secondaryFeedbackAction }) =>
    [feedbackAction?.value, secondaryFeedbackAction?.value]), [
    ["first", "second"], [undefined, "second"], [undefined, undefined],
  ]);
  assert.ok(presentations.every((event) => !Object.hasOwn(event, "primaryAction") && !Object.hasOwn(event, "secondaryAction")));
});

test("a selected toast action calls the current closure with the same Toast instance", async (t) => {
  const api = require("./view-api.cjs");
  const broker = require("./raycast-api.cjs");
  const events = [];
  t.mock.method(broker, "request", async (capability, text) => {
    if (capability === "feedback.toast") {
      events.push(JSON.parse(text));
      return "";
    }
    assert.equal(capability, "feedback.toastAction");
    assert.equal(text, events.at(-1).interaction.token);
    assert.notEqual(events[0].interaction.token, text);
    return "primary";
  });
  const command = () => api.Detail({ actions: api.ActionPanel({ children: api.Action({
    async onAction() {
      let counter = 0;
      const toast = await api.showToast({
        title: "Working",
        primaryAction: { title: "Old", shortcut: { key: "x", modifiers: ["cmd"] }, onAction: () => assert.fail("stale action") },
        secondaryAction: { title: "Invalid chord", shortcut: { key: "f", modifiers: ["opt", "opt"] }, onAction() {} },
      });
      toast.primaryAction = { title: "Retry", shortcut: { macOS: { key: "r", modifiers: ["ctrl", "shift"] } }, async onAction(active) {
        assert.equal(active, toast);
        await active.hide();
        await api.Clipboard.copy(String(++counter));
      } };
      counter = 8;
    },
  }) }) });
  const result = await api.render(command, { action: { row: 0, id: 0 }, liveToast: true, interactiveToast: true });
  assert.deepEqual(result, { kind: "copy", text: "9" });
  assert.deepEqual(events.map(({ interaction }) => interaction?.primaryShortcut), [
    { key: "x", modifiers: ["cmd"] }, { key: "r", modifiers: ["ctrl", "shift"] }, undefined, undefined,
  ]);
  assert.ok(events.every(({ interaction }) => interaction?.secondaryShortcut === undefined));
  assert.deepEqual(events.map(({ operation, interaction }) => [operation, interaction?.primary]), [
    ["show", "Old"], ["update", "Retry"], ["update", undefined], ["hide", undefined],
  ]);
});

test("toast clicks can abort a pending selected action before its original work finishes", async (t) => {
  const { setTimeout: delay } = require("node:timers/promises");
  const api = require("./view-api.cjs");
  const broker = require("./raycast-api.cjs");
  let token;
  let polls = 0;
  t.mock.method(broker, "request", async (capability, text) => {
    if (capability === "feedback.toast") {
      const event = JSON.parse(text);
      token = event.interaction?.token;
      return "";
    }
    assert.equal(capability, "feedback.toastAction");
    assert.equal(text, token + ":poll");
    return ++polls === 1 ? "" : "primary";
  });
  const command = () => api.Detail({ actions: api.ActionPanel({ children: api.Action({
    async onAction() {
      const controller = new AbortController();
      await api.showToast({
        title: "Running", style: api.Toast.Style.Animated,
        primaryAction: { title: "Cancel", onAction: () => controller.abort() },
      });
      await assert.rejects(delay(2000, undefined, { signal: controller.signal }), { name: "AbortError" });
      await api.Clipboard.copy("Cancelled before completion");
    },
  }) }) });
  assert.deepEqual(await api.render(command, { action: { row: 0, id: 0 }, liveToast: true, interactiveToast: true }),
    { kind: "copy", text: "Cancelled before completion" });
  assert.equal(polls, 2);
});

test("a selected action can refresh the same Toast and handle another click", async (t) => {
  const api = require("./view-api.cjs");
  const broker = require("./raycast-api.cjs");
  const tokens = [];
  let previous;
  t.mock.method(broker, "request", async (capability, text) => {
    if (capability === "feedback.toast") {
      const event = JSON.parse(text);
      previous = event.interaction;
      return "";
    }
    assert.equal(capability, "feedback.toastAction");
    assert.equal(text, previous.token);
    assert.ok(!tokens.includes(text));
    tokens.push(text);
    return previous.secondary ? "secondary" : "primary";
  });
  const command = () => api.Detail({ actions: api.ActionPanel({ children: api.Action({
    async onAction() {
      let attempts = 0;
      const toast = await api.showToast({ title: "Retry", primaryAction: { title: "Retry", onAction(active) {
        assert.equal(active, toast);
        if (++attempts < 2) return;
        active.primaryAction = undefined;
        active.secondaryAction = { title: "Finish", async onAction(again) {
          assert.equal(again, toast);
          await again.hide();
          await api.Clipboard.copy(String(attempts));
        } };
      } } });
    },
  }) }) });
  assert.deepEqual(await api.render(command, { action: { row: 0, id: 0 }, liveToast: true, interactiveToast: true }),
    { kind: "copy", text: "2" });
  assert.equal(tokens.length, 3);
});

test("no-view toast callbacks keep command state and expire when dismissed", async (t) => {
  const api = require("./raycast-api.cjs");
  const selections = [];
  const events = [];
  let trusted = true;
  t.mock.method(api, "request", async (capability, text) => {
    if (capability === "preferences.read") {
      return JSON.stringify({ preferences: { defaultAction: "copy" }, interactiveToast: trusted });
    }
    if (capability === "feedback.toast") {
      events.push(JSON.parse(text));
      return "";
    }
    assert.equal(capability, "feedback.toastAction");
    assert.equal(text, events.at(-1).interaction.token);
    return selections.shift();
  });

  await api.loadPreferences();
  selections.push("primary", "dismiss");
  let count = 0;
  await api.runNoViewCommand(async () => {
    const toast = await api.showToast({ title: "Ready", primaryAction: {
      title: "Increment", onAction(active) {
        assert.equal(active, toast);
        count++;
        active.primaryAction = undefined;
        active.secondaryAction = { title: "Expired", onAction() { assert.fail("dismissed callback ran"); } };
      },
    } });
  });
  assert.equal(count, 1);
  const published = events.flatMap(({ interaction }) => interaction ? [interaction] : []);
  assert.deepEqual(published.map(({ primary, secondary }) => primary ?? secondary), ["Increment", "Expired"]);
  assert.notEqual(published[0].token, published[1].token);
  assert.equal(events.at(-1).interaction, undefined);
  assert.equal(selections.length, 0);

  trusted = false;
  await api.loadPreferences();
  await api.runNoViewCommand(() => api.showToast({
    title: "Without a grant", primaryAction: { title: "Blocked", onAction() { assert.fail("grant bypass"); } },
  }));
  assert.equal(events.at(-1).interaction, undefined);
});
