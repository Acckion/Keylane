const assert = require("node:assert/strict");
const test = require("node:test");
const { makeApplicationQueries } = require("./applications-api.cjs");

test("application queries forward only a content type hint to the host", async () => {
  const calls = [];
  const application = { name: "Fixture Editor", path: "/Applications/Fixture Editor.app" };
  const api = makeApplicationQueries(async (capability, text) => {
    const request = JSON.parse(text);
    calls.push([capability, request]);
    return JSON.stringify(request.operation === "list" ? [application] : application);
  });

  assert.deepEqual(await api.getApplications(), [application]);
  assert.deepEqual(await api.getApplications(new URL("file:///fixture/private/File.TXT")), [application]);
  assert.deepEqual(await api.getDefaultApplication(Buffer.from("/fixture/private/File.txt")), application);
  assert.deepEqual(await api.getApplications("/fixture/private/Folder/"), [application]);
  assert.deepEqual(await api.getFrontmostApplication(), application);
  assert.deepEqual(calls, [
    ["applications.query", { operation: "list" }],
    ["applications.query", { operation: "list", extension: "txt" }],
    ["applications.query", { operation: "default", extension: "txt" }],
    ["applications.query", { operation: "list", directory: true }],
    ["applications.query", { operation: "frontmost" }],
  ]);
});

test("unsupported paths and broker denials stay observable", async () => {
  let requests = 0;
  const api = makeApplicationQueries(async () => {
    requests++;
    throw new Error("Capability unavailable for this command");
  });
  await assert.rejects(api.getDefaultApplication(undefined), TypeError);
  await assert.rejects(api.getDefaultApplication("README"), /filename extension/);
  await assert.rejects(api.getApplications("a\0b.txt"), TypeError);
  await assert.rejects(api.getApplications(new URL("https://example.com/file.txt")), TypeError);
  await assert.rejects(api.getApplications(Buffer.from([0xff])), TypeError);
  await assert.rejects(api.getFrontmostApplication(), /Capability unavailable/);
  assert.equal(requests, 1);
});
