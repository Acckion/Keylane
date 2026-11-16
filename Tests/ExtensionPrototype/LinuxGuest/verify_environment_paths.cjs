const assert = require("node:assert/strict");
const { test } = require("node:test");
const { configureEnvironment, environment } = require("./environment.cjs");

test("extension paths are fixed to guest directories across runtime modes", () => {
  for (const entryPointMode of ["view", "no-view", "menu-bar"]) {
    configureEnvironment({ entryPointMode, assetsPath: "/host/assets", supportPath: "/host/support" });
    assert.equal(environment.entryPointMode, entryPointMode);
    assert.equal(environment.assetsPath, "/assets");
    assert.equal(environment.supportPath, "/support");
  }
  configureEnvironment(undefined);
});

test("legacy launch context exposes an immutable snapshot of host JSON", () => {
  const launchContext = JSON.parse('{"nested":{"labels":["中文",false,null]},"__proto__":{"ownData":true}}');
  configureEnvironment({ launchContext });
  launchContext.nested.labels[0] = "changed";
  assert.deepEqual(environment.launchContext.nested.labels, ["中文", false, null]);
  assert.equal(Object.hasOwn(environment.launchContext, "__proto__"), true);
  assert.equal(Object.getPrototypeOf(environment.launchContext), Object.prototype);
  assert.equal(environment.launchContext.ownData, undefined);
  assert.equal(Object.isFrozen(environment.launchContext), true);
  assert.equal(Object.isFrozen(environment.launchContext.nested), true);
  assert.equal(Object.isFrozen(environment.launchContext.nested.labels), true);
  configureEnvironment(undefined);
  assert.equal(environment.launchContext, undefined);
});

test("legacy launch context omits malformed or oversized values", () => {
  const circular = {};
  circular.self = circular;
  for (const launchContext of [undefined, null, ["list"], "string", 1, circular, { text: "中".repeat(700) }]) {
    configureEnvironment({ launchContext });
    assert.equal(environment.launchContext, undefined);
  }
  configureEnvironment(undefined);
});
