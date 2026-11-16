const assert = require("node:assert/strict");
const test = require("node:test");
const { checkedViewRoute, makePushNavigation, maximumViewDepth, pushActionComponent } = require("./push-navigation.cjs");
const { Action, ActionPanel, Detail, List, LocalStorage, PushAction, open, render, useNavigation } = require("./view-api.cjs");

function node(type, props) {
  return { type, props };
}

const target = node("detail", { markdown: "Pong" });

test("view routes accept bounded action selectors and normalized input", () => {
  const frame = { query: "测试", dropdownValue: "a", row: -1, id: 11, mode: "action" };
  assert.deepEqual(checkedViewRoute(undefined), []);
  assert.deepEqual(checkedViewRoute([frame]), [frame]);
  assert.throws(() => checkedViewRoute(Array(maximumViewDepth + 1).fill(frame)), /route depth/);
  for (const changed of [{ row: -2 }, { id: 12 }, { mode: "openURL" }, { query: "测".repeat(86) }, { dropdownValue: 4 }]) {
    assert.throws(() => checkedViewRoute([{ ...frame, ...changed }]), /route frame/);
  }
});

test("declarative Push reconstructs its target without executing lifecycle callbacks", async () => {
  const Push = pushActionComponent((type) => (props) => node(type, props));
  const pushed = Push({ target, onPush: assert.fail, onPop: assert.fail });
  const navigation = makePushNavigation(() => assert.fail("Unexpected host action"));

  const effect = navigation.begin(pushed);
  assert.equal(effect.kind, "pushView");
  assert.equal(effect.routeMode, "action");
  assert.match(effect.lifecycleReceipt, /^[a-f0-9]{64}$/);
  assert.equal(await navigation.replay(pushed, "action"), target);
  await assert.rejects(navigation.replay(pushed, "callback"), /Unknown view route action/);
  assert.throws(() => navigation.begin(Push({ target: node("item", {}) })), /navigation target/);
});

test("only native push and pop transitions trigger their bound lifecycle callbacks", async () => {
  const { Cache, useState } = require("./view-api.cjs");
  const calls = [];
  let lateWrite;
  let lateCache;
  const command = () => {
    const [caption, setCaption] = useState("root");
    return Detail({ markdown: caption, actions: panel(PushAction({
      title: "Push child", target: Detail({ markdown: "child" }),
      async onPush() {
        calls.push("push");
        await LocalStorage.setItem("push", "1");
        const cache = new Cache();
        cache.set("push", "1");
        lateWrite = new Promise((resolve) => setTimeout(resolve, 10)).then(() => LocalStorage.setItem("late", "1"));
        lateCache = new Promise((resolve) => setTimeout(resolve, 10)).then(() => cache.set("late", "1"));
        lateWrite.catch(() => {});
        lateCache.catch(() => {});
      },
      async onPop() {
        calls.push("pop");
        await LocalStorage.setItem("pop", "1");
        setCaption("restored");
      },
    })) });
  };
  const action = { row: 0, id: 0 };
  const query = "parent";
  const initial = await render(command, { query, action });
  const frame = { query, ...action, mode: initial.routeMode, lifecycleReceipt: initial.lifecycleReceipt };
  const viewRoute = [frame];
  assert.equal((await render(command, { viewRoute })).detail.markdown, "child");
  assert.deepEqual(calls, []);
  const entered = await render(command, { viewRoute, notifyPush: true, storage: {}, cache: [] });
  assert.equal(entered.detail.markdown, "child");
  assert.equal(entered.storage.push, "1");
  assert.deepEqual(entered.cache, [[JSON.stringify(["", "push"]), "1"]]);
  await assert.rejects(lateWrite, /Navigation callback has ended/);
  await assert.rejects(lateCache, /Cache changes are unavailable/);
  const reopened = await render(command, { viewRoute, storage: { push: "1" } });
  assert.equal(reopened.detail.markdown, "child");
  assert.deepEqual(calls, ["push"]);
  const returned = await render(command, { query, poppedFrame: frame, storage: { push: "1" } });
  assert.equal(returned.detail.markdown, "restored");
  assert.equal(returned.storage.pop, "1");
  assert.deepEqual(calls, ["push", "pop"]);
  await assert.rejects(render(command, { viewRoute, notifyPush: true, action }), /Invalid navigation transition/);
  await assert.rejects(render(command, { query, poppedFrame: { ...frame, lifecycleReceipt: "0".repeat(64) } }),
    /Invalid navigation lifecycle receipt/);
});

test("lifecycle failures preserve the navigation result and cannot launch host file actions", async () => {
  const command = () => Detail({ actions: panel(Action.Push({
    title: "Push child", target: Detail({ markdown: "child" }),
    onPush: () => open("https://example.invalid"),
  })) });
  const action = { row: 0, id: 0 };
  const initial = await render(command, { action });
  const viewRoute = [{ ...action, mode: initial.routeMode, lifecycleReceipt: initial.lifecycleReceipt }];
  const result = await render(command, { viewRoute, notifyPush: true });
  assert.equal(result.kind, "detail");
  assert.equal(result.lifecycleFailed, true);
});

test("navigation replays one awaited push without emitting host actions", async () => {
  let enabled = false;
  const recorded = [];
  const navigation = makePushNavigation((effect) => {
    if (!enabled) throw new Error("No selected view action");
    recorded.push(effect);
  });
  const { push, pop } = navigation.useNavigation();
  const callback = node("callback", { onAction: async () => { await Promise.resolve(); push(target); } });
  assert.throws(() => push(target), /No selected view action/);
  assert.throws(pop, /No selected view action/);
  assert.equal(await navigation.replay(callback, "callback"), target);
  assert.deepEqual(recorded, []);

  enabled = true;
  await callback.props.onAction();
  pop();
  assert.deepEqual(recorded, [{ kind: "pushView", routeMode: "callback" }, { kind: "popView" }]);
  await assert.rejects(navigation.replay(node("callback", { onAction: pop }), "callback"), /Cannot pop/);
  await assert.rejects(navigation.replay(node("callback", { onAction() { push(target); push(target); } }), "callback"), /Expected one push/);
});

test("detached continuations cannot push after route replay ends", async () => {
  const { replay, useNavigation } = makePushNavigation(() => assert.fail("Unexpected host action"));
  const { push } = useNavigation();
  let delayed;
  const callback = node("callback", {
    onAction() {
      push(target);
      delayed = new Promise((resolve) => setImmediate(() => {
        assert.throws(() => push(target), /reconstructing a view route/);
        resolve();
      }));
    },
  });
  assert.equal(await replay(callback, "callback"), target);
  await delayed;
});

function panel(...children) {
  return ActionPanel({ children });
}

test("the signed view API replays nested Push and callback routes and restores a searchable parent", async () => {
  assert.equal(PushAction, Action.Push);
  const command = () => {
    const { push, pop } = useNavigation();
    return List({ children: ["Apple", "Banana"].map((title) => List.Item({
      title,
      actions: panel(PushAction({
        title: "Open Detail",
        target: Detail({
          markdown: title,
          actions: panel(Action({ title: "Open Child", onAction: async () => {
            await Promise.resolve();
            push(Detail({ markdown: `${title} child`, actions: panel(Action({ title: "Back", onAction: pop })) }));
          } })),
        }),
      })),
    })) });
  };
  const action = { row: 0, id: 0 };
  const query = "Banana";
  const root = await render(command, { query });
  assert.equal(root.rows[0].actions[0].kind, "push");
  const first = await render(command, { query, action });
  assert.deepEqual(first, { kind: "pushView", routeMode: "action" });
  const viewRoute = [{ query, ...action, mode: first.routeMode }];
  assert.equal((await render(command, { query: "", viewRoute })).detail.markdown, "Banana");

  const second = await render(command, { query: "", viewRoute, action });
  assert.deepEqual(second, { kind: "pushView", routeMode: "callback" });
  viewRoute.push({ query: "", ...action, mode: second.routeMode });
  assert.equal((await render(command, { query: "", viewRoute })).detail.markdown, "Banana child");
  assert.deepEqual(await render(command, { query: "", viewRoute, action }), { kind: "popView" });
  viewRoute.pop();
  assert.equal((await render(command, { query: "", viewRoute })).detail.markdown, "Banana");
  viewRoute.pop();
  assert.deepEqual((await render(command, { query, viewRoute })).rows.map(({ title }) => title), ["Banana"]);
});

test("route reconstruction cannot perform actions or write storage", async () => {
  const action = { row: 0, id: 0 };
  const viewRoute = [{ ...action, mode: "callback" }];
  function command(onAction) {
    return () => Detail({ markdown: "Root", actions: panel(Action({ title: "Action", onAction })) });
  }

  await assert.rejects(render(command(() => open("https://example.com")), { viewRoute }), /selected view action/);
  await assert.rejects(render(command(() => LocalStorage.setItem("key", "value")), { storage: {}, viewRoute }), /reconstructing view inputs/);
  await assert.rejects(render(() => {
    useNavigation().push(Detail({ markdown: "Child" }));
  }, {}), /selected view action/);
});

test("detached replay callbacks cannot write storage after the next action starts", async () => {
  const action = { row: 0, id: 0 };
  const viewRoute = [{ ...action, mode: "callback" }];
  let detachedWrite;
  const command = () => {
    const { push, pop } = useNavigation();
    return Detail({ markdown: "Root", actions: panel(Action({ title: "Push", onAction() {
      detachedWrite = new Promise((resolve) => setImmediate(resolve)).then(() => LocalStorage.setItem("late", "write"));
      detachedWrite.catch(() => {});
      push(Detail({ markdown: "Child", actions: panel(Action({ title: "Back", onAction: pop })) }));
    } })) });
  };

  assert.deepEqual(await render(command, { action, storage: {}, viewRoute }), { kind: "popView" });
  await assert.rejects(detachedWrite, /reconstructing view inputs/);
});
