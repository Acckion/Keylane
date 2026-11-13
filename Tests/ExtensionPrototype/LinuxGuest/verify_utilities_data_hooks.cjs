const assert = require("node:assert/strict");
const { mkdtemp, rm, writeFile } = require("node:fs/promises");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { pathToFileURL } = require("node:url");
const { DatabaseSync } = require("node:sqlite");
const test = require("node:test");
const { Detail, render } = require("./view-api.cjs");
const { FormValidation, executeSQL } = require("./raycast-utils.cjs");
const { utilitiesHooksFor } = require("./utilities-hooks.cjs");
const { utilitiesDataHooksFor } = require("./utilities-data-hooks.cjs");

const { usePromise } = utilitiesHooksFor(() => require("./view-api.cjs"), FormValidation);
const { useFetch, useStreamJSON, useSQL } = utilitiesDataHooksFor(usePromise, executeSQL);

async function hookSnapshot(hook) {
  const reply = await render(() => {
    const { data, error, isLoading, permissionView } = hook();
    return Detail({ markdown: JSON.stringify({ data, error: error?.message, isLoading, permissionView }) });
  }, {});
  return JSON.parse(reply.detail.markdown);
}

async function withFixtures(run) {
  const directory = await mkdtemp(join(tmpdir(), "keylane-data-hooks-"));
  try {
    return await run(directory);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

test("useFetch resolves a data URL as JSON or text and invokes transforms", async () => {
  const json = "data:application/vnd.keylane+json," + encodeURIComponent('{"title":"来宾"}');
  let onData;
  assert.deepEqual(await hookSnapshot(() => useFetch(new Request(json), {
    mapResult: ({ title }) => ({ data: title }),
    onData: (data) => { onData = data; },
  })), { data: "来宾", isLoading: false });
  assert.equal(onData, "来宾");
  const url = new URL("data:text/plain,hello");
  assert.equal((await hookSnapshot(() => useFetch(url))).data, "hello");
  const custom = await hookSnapshot(() => useFetch(url, {
    parseResponse: async (response) => (await response.text()).toUpperCase(),
  }));
  assert.equal(custom.data, "HELLO");
});

test("useFetch reports invalid JSON and refuses non-inline resources", async () => {
  for (const input of ["https://example.invalid/", "file:///tmp/test.json"]) {
    assert.match((await hookSnapshot(() => useFetch(input))).error, /inline data URL/);
  }
  assert.match((await hookSnapshot(() => useFetch("data:application/json,malformed"))).error, /JSON|Unexpected/);
  assert.deepEqual(await hookSnapshot(() => useFetch("https://example.invalid", {
    execute: false, initialData: ["initial"],
  })), { data: ["initial"], isLoading: false });
});

test("useStreamJSON reads chunked arrays and transforms and filters items", async () => {
  await withFixtures(async (directory) => {
    const file = join(directory, "stream fixture.json");
    const first = "x".repeat(16374) + "字\\\"],";
    await writeFile(file, JSON.stringify([{ name: first }, { name: "discard" }, { name: "保留" }, [7]]));
    const snapshot = await hookSnapshot(() => useStreamJSON(pathToFileURL(file), {
      transform: (item) => Array.isArray(item) ? item : [item.name],
      filter: (item) => item !== "discard",
    }));
    assert.deepEqual(snapshot, { data: [first, "保留", 7], isLoading: false });
    assert.deepEqual((await hookSnapshot(() => useStreamJSON(pathToFileURL(file)))).data.at(-1), [7]);
  });
});

test("useStreamJSON selects nested arrays and rejects invalid or oversized input", async () => {
  await withFixtures(async (directory) => {
    const file = join(directory, "nested.json");
    const url = pathToFileURL(file).href;
    await writeFile(file, JSON.stringify({ results: { first: [1, 2], second: ["三"] }, other: [4] }));
    assert.deepEqual((await hookSnapshot(() => useStreamJSON(url, { dataPath: "results.first" }))).data, [1, 2]);
    assert.deepEqual((await hookSnapshot(() => useStreamJSON(url, { dataPath: /^results\.(first|second)$/g }))).data, [1, 2, "三"]);
    assert.deepEqual((await hookSnapshot(() => useStreamJSON(url, { dataPath: "__proto__.first" }))).data, []);
    assert.match((await hookSnapshot(() => useStreamJSON(url))).error, /JSON array/);

    for (const invalid of ["[1,]", "[1,2", "[]trailing", '[{"bad":]}]']) {
      await writeFile(file, invalid);
      assert.equal(typeof (await hookSnapshot(() => useStreamJSON(url))).error, "string");
    }
    await writeFile(file, Buffer.alloc(1024 * 1024 + 1));
    assert.match((await hookSnapshot(() => useStreamJSON(url))).error, /input exceeds/);
    await writeFile(file, JSON.stringify(Array(2049).fill(1)));
    assert.match((await hookSnapshot(() => useStreamJSON(url))).error, /item limit/);
    assert.match((await hookSnapshot(() => useStreamJSON("https://example.invalid/a"))).error, /guest-local file/);
  });
});

test("useSQL reads a guest database and preserves read-only validation", async () => {
  await withFixtures(async (directory) => {
    const file = join(directory, "sample.sqlite");
    const database = new DatabaseSync(file);
    database.exec("CREATE TABLE samples (name TEXT); INSERT INTO samples VALUES ('中文');");
    database.close();
    assert.deepEqual(await hookSnapshot(() => useSQL(file, "SELECT name FROM samples")), {
      data: [{ name: "中文" }], isLoading: false, permissionView: null,
    });
    assert.match((await hookSnapshot(() => useSQL(file, "DELETE FROM samples"))).error, /read-only/);
    assert.match((await hookSnapshot(() => useSQL(file, "DELETE FROM samples RETURNING name"))).error, /read.?only/i);
    assert.match((await hookSnapshot(() => useSQL(join(directory, "missing"), "SELECT 1"))).error, /does not exist/);
  });
});
