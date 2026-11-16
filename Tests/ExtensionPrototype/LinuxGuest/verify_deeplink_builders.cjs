const assert = require("node:assert/strict");
const { afterEach, beforeEach, test } = require("node:test");
const { configureEnvironment } = require("./environment.cjs");
const {
  createDeeplink, createExtensionDeeplink, createScriptCommandDeeplink,
} = require("./utilities-deeplinks.cjs");

const previousScheme = process.env.RAYCAST_SCHEME;

beforeEach(() => {
  delete process.env.RAYCAST_SCHEME;
  configureEnvironment({ ownerOrAuthorName: "fixture", extensionName: "example" });
});

afterEach(() => {
  configureEnvironment();
  if (previousScheme === undefined) delete process.env.RAYCAST_SCHEME;
  else process.env.RAYCAST_SCHEME = previousScheme;
});

test("extension links use the invocation identity and serialize Raycast parameters in order", () => {
  const options = {
    command: "search",
    launchType: "background",
    arguments: { query: "你好 / café", empty: "" },
    context: { origin: ["one", 2] },
    fallbackText: "标题 & #tag",
  };
  const expected = "raycast://extensions/fixture/example/search?launchType=background" +
    "&arguments=%7B%22query%22%3A%22%E4%BD%A0%E5%A5%BD%20%2F%20caf%C3%A9%22%2C%22empty%22%3A%22%22%7D" +
    "&context=%7B%22origin%22%3A%5B%22one%22%2C2%5D%7D" +
    "&fallbackText=%E6%A0%87%E9%A2%98%20%26%20%23tag";
  assert.equal(createExtensionDeeplink(options), expected);
  assert.equal(createDeeplink({ type: "extension", ...options }), expected);
  assert.equal(createDeeplink(options), expected);
});

test("external extension links use the explicit target without reading caller metadata", () => {
  configureEnvironment();
  const options = { ownerOrAuthorName: "test-owner", extensionName: "other", command: "details" };
  const expected = "raycast://extensions/test-owner/other/details";
  assert.equal(createExtensionDeeplink(options), expected);
  assert.equal(createDeeplink({ ...options, fallbackText: "" }), expected);
  assert.throws(() => createDeeplink({ command: "internal" }), /extension owner and name/);
});

test("script links preserve repeated arguments, blank values, and the Raycast beta scheme", () => {
  process.env.RAYCAST_SCHEME = "raycast-beta";
  const options = { type: "script-command", command: "demo", arguments: ["中文 &", "", "a+b"] };
  const expected = "raycast-beta://script-commands/demo?arguments=%E4%B8%AD%E6%96%87%20%26&arguments=&arguments=a%2Bb";
  assert.equal(createScriptCommandDeeplink(options), expected);
  assert.equal(createDeeplink(options), expected);
  assert.equal(createDeeplink({ ...options, arguments: [] }), "raycast-beta://script-commands/demo?");
  assert.equal(createDeeplink({ ...options, arguments: undefined }), "raycast-beta://script-commands/demo");
  assert.equal(createDeeplink({ command: "internal" }), "raycast-beta://extensions/fixture/example/internal");
});
