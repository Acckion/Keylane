const assert = require("node:assert/strict");
const { test } = require("node:test");
const { trashComponent, trashEffect, makeTrash } = require("./trash-action.cjs");

test("Trash action describes a destructive proposal without moving files", () => {
  const Trash = trashComponent((type) => (props) => ({ type, props }));
  const paths = ["/tmp/中文.txt"];
  const expected = { type: "trashFiles", props: { paths, title: "Move to Trash", icon: "trash-16", style: "destructive" } };
  assert.deepEqual(Trash({ paths }), expected);
  assert.deepEqual(Trash({ paths, title: "Clean up", style: "regular" }), {
    ...expected,
    props: { ...expected.props, title: "Clean up" },
  });
});

test("Trash requests support single and multiple PathLike inputs with stable deduplication", async () => {
  assert.deepEqual(trashEffect(new URL("file:///tmp/some%20file")), {
    kind: "trashFiles", paths: ["/tmp/some file"],
  });

  const calls = [];
  const trash = makeTrash((effect) => calls.push(effect));
  await trash(["/tmp/中文.txt", Buffer.from("/tmp/other"), "/tmp/中文.txt"]);
  assert.deepEqual(calls, [{ kind: "trashFiles", paths: ["/tmp/中文.txt", "/tmp/other"] }]);
});

test("Trash rejects invalid targets and preserves selected-action errors", async () => {
  const trash = makeTrash(() => assert.fail("invalid target emitted a request"));
  await assert.rejects(trash([]), RangeError);
  await assert.rejects(trash(Array.from({ length: 9 }, (_, index) => `/tmp/${index}`)), RangeError);
  for (const path of ["/", "~/Documents", "relative", new URL("https://example.com/path"), "/tmp/line\nbreak"]) {
    await assert.rejects(trash(path), TypeError);
  }
  const longPaths = ["a", "b", "c"].map((prefix) => `/${prefix.repeat(1500)}`);
  await assert.rejects(trash(longPaths), TypeError);
  const unavailable = makeTrash(() => { throw new Error("Requires a selected action"); });
  await assert.rejects(unavailable("/tmp/synthetic"), /selected action/);
});
