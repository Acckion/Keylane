const assert = require("node:assert/strict");
const test = require("node:test");
const { makeClipboardReaders } = require("./clipboard-read.cjs");
const { environment, registerEnvironmentCapability } = require("./environment.cjs");

test("Clipboard readers request the appropriate bounded representation and represent an empty clipboard", async () => {
  let response = '{"text":"合成文本","html":"<b>合成文本</b>","file":"/tmp/合成.pdf","secret":"discard"}';
  const calls = [];
  const readers = makeClipboardReaders(async (capability, text) => {
    calls.push([capability, text]);
    return response;
  }, () => true);

  assert.deepEqual(await readers.read(), { text: "合成文本", html: "<b>合成文本</b>", file: "/tmp/合成.pdf" });
  assert.equal(await readers.readText({ offset: 0 }), "合成文本");
  assert.deepEqual(await readers.read({ offset: 5 }), { text: "合成文本", html: "<b>合成文本</b>", file: "/tmp/合成.pdf" });
  assert.equal(await readers.readText({ offset: 1 }), "合成文本");
  assert.deepEqual(calls, [
    ["clipboard.read", "content"], ["clipboard.read", ""],
    ["clipboard.read", "content:5"], ["clipboard.read", "text:1"],
  ]);
  response = '{}';
  assert.deepEqual(await readers.read(), {});
  assert.equal(await readers.readText(), undefined);
});

test("Clipboard reads reject invalid offsets, unavailable scope, and invalid broker results", async () => {
  let allowed = false;
  let response = '{}';
  let calls = 0;
  const readers = makeClipboardReaders(async () => { calls++; return response; }, () => allowed);

  await assert.rejects(readers.read(), /selected view action/);
  await assert.rejects(readers.readText({ offset: 1 }), /selected view action/);
  for (const offset of [-1, 6, 1.5, "1", null]) {
    await assert.rejects(readers.readText({ offset }), /integer from 0 to 5/);
  }
  assert.equal(calls, 0);
  allowed = true;
  response = '{"text":7}';
  await assert.rejects(readers.read(), /Invalid clipboard text/);
  response = JSON.stringify({ text: "x".repeat(32 * 1024 + 1) });
  await assert.rejects(readers.readText(), /Invalid clipboard text/);
  response = JSON.stringify({ html: "x".repeat(32 * 1024 + 1) });
  await assert.rejects(readers.read(), /Invalid clipboard html/);
  assert.equal(await readers.readText(), undefined);
  response = '{"file":false}';
  await assert.rejects(readers.read(), /Invalid clipboard file/);
  response = "[]";
  await assert.rejects(readers.read(), /Invalid clipboard result/);
});

test("environment.canAccess follows registered API identity and current scope", () => {
  let allowed = false;
  const api = makeClipboardReaders(() => assert.fail("canAccess must not query the host"), () => allowed);
  registerEnvironmentCapability(api, () => allowed);
  registerEnvironmentCapability(api.read, () => allowed);

  assert.equal(environment.canAccess(api), false);
  allowed = true;
  assert.equal(environment.canAccess(api), true);
  assert.equal(environment.canAccess(api.read), true);
  assert.equal(environment.canAccess({ ...api }), false);
  assert.equal(environment.canAccess(api.readText), false);
  assert.equal(environment.canAccess(null), false);
  assert.equal(environment.canAccess("Clipboard"), false);
  allowed = false;
  assert.equal(environment.canAccess(api.read), false);
});

test("no-view clipboard reads are exposed only during an authorized command", async () => {
  const api = require("./raycast-api.cjs");
  const previous = api.request;
  const calls = [];
  api.request = async (capability, selector) => {
    if (capability === "preferences.read") return '{"clipboardReadAllowed":true}';
    calls.push([capability, selector]);
    return '{"text":"fixture"}';
  };
  try {
    await api.loadPreferences();
    assert.equal(api.environment.canAccess(api.Clipboard), false);
    await assert.rejects(api.Clipboard.read(), /requires a selected view action/);
    let detached;
    await api.runNoViewCommand(async () => {
      assert.equal(api.environment.canAccess(api.Clipboard.readText), true);
      assert.equal(await api.Clipboard.readText({ offset: 2 }), "fixture");
      detached = new Promise((resolve, reject) => setImmediate(async () => {
        try {
          assert.equal(api.environment.canAccess(api.Clipboard), false);
          await assert.rejects(api.Clipboard.read(), /requires a selected view action/);
          resolve();
        } catch (error) { reject(error); }
      }));
    });
    await detached;
    assert.deepEqual(calls, [["clipboard.read", "text:2"]]);
  } finally {
    api.request = previous;
  }
});

test("UUID Suite clipboard reads stay inside the authorized no-view command", async (t) => {
  const broker = require("./raycast-api.cjs");
  const api = require("./view-api.cjs");
  const request = t.mock.method(broker, "request", async (capability, selector) => {
    assert.equal(capability, "clipboard.read");
    assert.equal(selector, "text:1");
    return '{"text":"fixture"}';
  });
  const input = { mode: "generate", storage: {}, suitePreferencesAllowed: true, clipboardReadAllowed: true };
  const denied = async () => {
    assert.equal(api.environment.canAccess(api.Clipboard), false);
    await assert.rejects(api.Clipboard.read(), /requires a selected view action/);
  };
  await denied();
  await api.runCommand(denied, { ...input, clipboardReadAllowed: false });
  await api.runCommand(denied, { ...input, suitePreferencesAllowed: false });
  await api.runCommand(denied, { ...input, sensitiveFormSubmission: true });

  let detached;
  await api.runCommand(async () => {
    assert.equal(api.environment.canAccess(api.Clipboard.readText), true);
    assert.equal(await api.Clipboard.readText({ offset: 1 }), "fixture");
    detached = new Promise((resolve, reject) => setImmediate(() => denied().then(resolve, reject)));
  }, input);
  await detached;
  assert.equal(request.mock.callCount(), 1);
});

test("clipboard transfers rebuild UTF-8 across frames and validate receipts and chunks", async () => {
  const transfer = "550e8400-e29b-41d4-a716-446655440000";
  const text = "中文😀\n".repeat(2000);
  const payload = Buffer.from(JSON.stringify({ text, html: "<b>" + text + "</b>" }));
  const selectors = [];
  let allowed = true;
  let bytes = payload.length;
  let corruptChunk = false;
  let expire = false;
  const readers = makeClipboardReaders(async (capability, selector) => {
    if (capability === "clipboard.read") return JSON.stringify({ transfer, bytes });
    assert.equal(capability, "clipboard.readChunk");
    const [id, offset] = selector.split(":");
    assert.equal(id, transfer);
    selectors.push(Number(offset));
    if (expire) allowed = false;
    const chunk = payload.subarray(Number(offset), Number(offset) + 11264).toString("base64");
    return corruptChunk ? chunk + "!" : chunk;
  }, () => allowed);

  assert.deepEqual(await readers.read({ offset: 2 }), { text, html: "<b>" + text + "</b>" });
  assert.deepEqual(selectors, [0, 11264, 22528, 33792, 45056]);
  corruptChunk = true;
  await assert.rejects(readers.readText(), /Invalid clipboard transfer chunk/);
  corruptChunk = false;
  expire = true;
  await assert.rejects(readers.read(), /authorization expired/);
  allowed = true;
  bytes = 64 * 1024 + 1;
  await assert.rejects(readers.read(), /Invalid clipboard transfer/);
});

test("user-opened view effects can read the clipboard without granting render or search callbacks access", async (t) => {
  const bridge = require("./raycast-api.cjs");
  const api = require("./view-api.cjs");
  const broker = t.mock.method(bridge, "request", async (capability, selector) => {
    assert.equal(capability, "clipboard.read");
    assert.equal(selector, "text:1");
    return '{"text":"fixture"}';
  });
  let afterMount;
  let finishMount;
  const mounted = new Promise((resolve) => { finishMount = resolve; });
  const denied = async () => {
    assert.equal(api.environment.canAccess(api.Clipboard), false);
    await assert.rejects(api.Clipboard.read(), /requires a selected view action/);
  };
  const makeView = (shouldRead) => () => {
    assert.equal(api.environment.canAccess(api.Clipboard), false);
    api.useEffect(async () => {
      if (!shouldRead) return denied();
      afterMount = mounted.then(denied);
      assert.equal(api.environment.canAccess(api.Clipboard.readText), true);
      assert.equal(await api.Clipboard.readText({ offset: 1 }), "fixture");
    });
    return api.List({ onSearchTextChange: denied });
  };
  const launch = { query: "", initialPreferencesAllowed: true, clipboardReadAllowed: true, mountNavigation: true };
  await api.render(makeView(true), launch);
  finishMount();
  await afterMount;
  await api.render(makeView(false), { ...launch, query: "refresh" });
  await api.render(makeView(false), { ...launch, initialPreferencesAllowed: false });
  await api.render(makeView(false), { ...launch, mountNavigation: false });
  await api.render(makeView(false), { ...launch, clipboardReadAllowed: false });
  assert.equal(broker.mock.callCount(), 1);
});
