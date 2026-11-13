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
