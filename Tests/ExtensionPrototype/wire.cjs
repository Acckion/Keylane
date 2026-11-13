const assert = require("node:assert/strict");
const readline = require("node:readline");

const [session, rawGeneration, mode] = process.argv.slice(2);
const generation = Number(rawGeneration);
const hello = { kind: "hello", session, generation, versions: [1] };
const request = { kind: "request", session, generation, version: 1, requestID: 1,
  capability: "echo", text: "Keylane 中文" };
const encode = (message) => JSON.stringify(message) + "\n";

async function run() {
  if (mode === "stall") {
    setInterval(() => {}, 1000);
    return;
  }
  if (mode === "partial") {
    process.stdout.write(encode(hello) + "{");
    return;
  }
  if (mode === "backpressure") {
    process.stdout.write(encode(hello));
    for (let requestID = 1; requestID < 16; requestID++) {
      process.stdout.write(encode({ ...request, requestID, text: "x".repeat(12000) }));
    }
    setInterval(() => {}, 1000);
    return;
  }
  console.error("reviewed fixture log");
  const reader = readline.createInterface({ input: process.stdin });
  const replies = reader[Symbol.asyncIterator]();
  const encodedHello = encode(hello);
  process.stdout.write(encodedHello.slice(0, 8));
  process.stdout.write(encodedHello.slice(8));
  const receive = async () => {
    const next = await replies.next();
    assert.equal(next.done, false);
    const reply = JSON.parse(next.value);
    assert.equal(reply.session, session);
    assert.equal(reply.generation, generation);
    return reply;
  };
  assert.equal((await receive()).kind, "ready");
  process.stdout.write(encode({ ...request, generation: generation - 1 }) + encode(request));
  const echo = await receive();
  assert.equal(echo.kind, "result");
  assert.equal(echo.text, request.text);
  process.stdout.write(encode({ ...request, requestID: 2, capability: "clipboard.read", extensionID: "forged" }));
  assert.equal((await receive()).kind, "denied");
  reader.close();
  process.stdin.pause();
}
run().catch((error) => {
  console.error(error);
  process.exit(1);
});
