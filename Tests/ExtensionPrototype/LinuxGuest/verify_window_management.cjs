const assert = require("node:assert/strict");
const test = require("node:test");
const { makeWindowManagement } = require("./window-management.cjs");

function windowFixture(id, active) {
  return {
    id,
    desktopId: "visible-desktop",
    active,
    positionable: false,
    resizable: false,
    fullScreenSettable: false,
    bounds: { position: { x: -24, y: 10 }, size: { width: 640, height: 480 } },
    application: { name: "Fixture", path: "/Applications/Fixture.app", bundleId: "test.fixture" },
  };
}

test("window APIs select the bounded read-only broker operations and strip unknown data", async () => {
  const active = windowFixture("12", true);
  const other = windowFixture("13", false);
  const operations = [];
  const manager = makeWindowManagement(async (capability, operation) => {
    operations.push([capability, operation]);
    return JSON.stringify(operation === "active" ? { ...active, title: "private" } : [other, active]);
  }, () => true);

  assert.equal(Object.isFrozen(manager), true);
  assert.deepEqual(await manager.getActiveWindow(), active);
  assert.deepEqual(await manager.getWindowsOnActiveDesktop(), [other, active]);
  assert.deepEqual(operations, [["window.read", "active"], ["window.read", "desktop"]]);
});

test("window API refuses unauthorized reads before contacting the broker", async () => {
  const manager = makeWindowManagement(() => assert.fail("no read allowed"), () => false);
  await assert.rejects(manager.getActiveWindow(), /selected view action/);
  await assert.rejects(manager.getWindowsOnActiveDesktop(), /selected view action/);
});

test("empty desktops, absent active windows and malformed responses have distinct outcomes", async () => {
  let reply;
  const manager = makeWindowManagement(async () => JSON.stringify(reply), () => true);
  reply = null;
  await assert.rejects(manager.getActiveWindow(), /No active window/);
  reply = [];
  assert.deepEqual(await manager.getWindowsOnActiveDesktop(), []);
  reply = [{ ...windowFixture("12", true), bounds: { size: { width: -1, height: 1 } } }];
  await assert.rejects(manager.getWindowsOnActiveDesktop(), /Invalid window bounds/);
  reply = Array.from({ length: 25 }, (_, index) => ({
    ...windowFixture(String(index), false), application: undefined,
  }));
  await assert.rejects(manager.getWindowsOnActiveDesktop(), /Invalid window list/);
  reply = "x".repeat(6001);
  await assert.rejects(manager.getWindowsOnActiveDesktop(), /Invalid window response/);
});
