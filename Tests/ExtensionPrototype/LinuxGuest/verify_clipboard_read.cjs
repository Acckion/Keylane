const assert = require("node:assert/strict");
const test = require("node:test");
const { makeClipboardReaders } = require("./clipboard-read.cjs");
const { environment, registerEnvironmentCapability } = require("./environment.cjs");

test("Clipboard readers share the bounded plain-text broker and represent an empty clipboard", async () => {
  let response = '{"text":"合成文本"}';
  const calls = [];
  const readers = makeClipboardReaders(async (capability, text) => {
    calls.push([capability, text]);
    return response;
  }, () => true);

  assert.deepEqual(await readers.read(), { text: "合成文本" });
  assert.equal(await readers.readText({ offset: 0 }), "合成文本");
  assert.deepEqual(calls, [["clipboard.read", ""], ["clipboard.read", ""]]);
  response = '{}';
  assert.deepEqual(await readers.read(), {});
  assert.equal(await readers.readText(), undefined);
});

test("Clipboard reads reject history, unavailable scope, and invalid broker results", async () => {
  let allowed = false;
  let response = '{}';
  let calls = 0;
  const readers = makeClipboardReaders(async () => { calls++; return response; }, () => allowed);

  await assert.rejects(readers.read(), /selected view action/);
  await assert.rejects(readers.readText({ offset: 1 }), /current clipboard/);
  assert.equal(calls, 0);
  allowed = true;
  response = '{"text":7}';
  await assert.rejects(readers.read(), /Invalid clipboard text/);
  response = JSON.stringify({ text: "x".repeat(2049) });
  await assert.rejects(readers.readText(), /Invalid clipboard text/);
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
