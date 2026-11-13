const assert = require("node:assert/strict");
const fs = require("node:fs");
const net = require("node:net");
const vm = require("node:vm");
const { spawnSync } = require("node:child_process");
const { Worker } = require("node:worker_threads");

async function run() {
  const [phase, hostSentinel, source] = process.argv.slice(2);
  const opposite = phase === "build" ? "run" : "build";
  assert.equal(fs.readFileSync(`/${phase}-only`, "utf8"), phase);
  assert.throws(() => fs.readFileSync(`/${opposite}-only`), { code: "ENOENT" });
  assert.throws(() => fs.readFileSync(hostSentinel), { code: "ENOENT" });
  const sourcePath = phase === "build" ? (source ?? "/dependency.ts") : "/sample.cjs";
  assert.throws(() => fs.appendFileSync(sourcePath, "unexpected"), { code: "EACCES" });
  assert.equal(spawnSync(process.execPath, ["-e", "process.exit(0)"]).error?.code, "EPERM");
  const thread = new Worker("require('node:worker_threads').parentPort.postMessage(42)", { eval: true });
  const threadResult = await new Promise((resolve, reject) => {
    thread.once("message", resolve);
    thread.once("error", reject);
  });
  assert.equal(threadResult, 42);
  await thread.terminate();
  console.error(`keylane: ${phase} spawn denied, worker thread passed`);
  const networkError = await new Promise((resolve, reject) => {
    const socket = net.connect({ host: "192.0.2.1", port: 443 });
    socket.once("connect", () => { socket.destroy(); reject(new Error("network reachable")); });
    socket.once("error", resolve);
    socket.setTimeout(750, () => { socket.destroy(); reject(new Error("network probe timed out")); });
  });
  assert.equal(networkError.code, "ENETUNREACH");

  if (phase === "build") {
    const bundle = fs.readFileSync("/work/bundle.cjs");
    new vm.Script(bundle.toString("utf8"), { filename: "sample.cjs" });
    // Keep the larger UUID suite inside the existing broker frame budget.
    const output = source === "/uuid-suite.ts" ? require("node:zlib").gzipSync(bundle) : bundle;
    process.stdout.write(output.toString("base64"));
  } else {
    process.stdout.write(Buffer.from(require("/sample.cjs")).toString("base64"));
  }
}
run().catch((error) => { console.error(error); process.exitCode = 1; });
