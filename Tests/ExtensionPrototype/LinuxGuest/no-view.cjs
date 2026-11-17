const assert = require("node:assert/strict");
const api = require("/raycast-api.cjs");

async function main() {
  api.connect();
  if (process.env.KEYLANE_PHASE === "noview-cancel") {
    console.error("keylane: Node waiting for host cancellation");
    setInterval(() => {}, 1000);
    return;
  }
  if (["noview-flood", "noview-backpressure"].includes(process.env.KEYLANE_PHASE)) {
    const readReplies = process.env.KEYLANE_PHASE === "noview-flood";
    if (!readReplies) console.error("keylane: Node withholding reply reads");
    api.flood(readReplies);
    setInterval(() => {}, 1000);
    return;
  }
  if (process.env.KEYLANE_PHASE === "noview-wire") {
    await assert.rejects(api.request("file.read", "sample"), /Capability unavailable/);
    const first = await api.showToast({ title: "Working", style: api.Toast.Style.Animated });
    first.title = "Done";
    first.style = api.Toast.Style.Success;
    await api.flushToastUpdates();
    const second = await api.showToast({ title: "Current" });
    await first.hide();
    await assert.rejects(api.request("feedback.toast", JSON.stringify({ operation: "hide", id: 1 })));
    await second.hide();
    await assert.rejects(api.request("feedback.toast", JSON.stringify({
      operation: "update", id: 2, title: "Stale", style: api.Toast.Style.Success,
    })));
    assert.equal(await api.request("echo", "node-confirmed"), "node-confirmed");
    return;
  }
  if (process.env.KEYLANE_PHASE === "noview-app") {
    await api.loadPreferences();
    require("./diagnostics-api.cjs").configureExceptionReporting((category) => api.request("diagnostics.exception", category));
  }
  const command = require("/sample.cjs").default;
  await api.runNoViewCommand(() => command({ arguments: { uuid: process.env.KEYLANE_PHASE === "noview-app" ? process.env.KEYLANE_UUID : "550e8400e29b41d4a716446655440000" } }));
  assert.equal(await api.request("echo", "node-confirmed"), "node-confirmed");
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
