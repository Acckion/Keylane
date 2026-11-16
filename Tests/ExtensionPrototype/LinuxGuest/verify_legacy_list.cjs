const assert = require("node:assert/strict");
const { test } = require("node:test");
const { randomId: noViewRandomId } = require("./raycast-api.cjs");
const { List, ListItem, ListSection, randomId, render } = require("./view-api.cjs");

test("deprecated ListItem and ListSection share list details, filtering, and grouping", async () => {
  assert.equal(ListItem, List.Item);
  assert.equal(ListSection, List.Section);

  const command = () => List({ children: ListSection({
    title: "Languages",
    children: [
      ListItem({ title: "中文", detail: ListItem.Detail({ markdown: "Chinese" }) }),
      ListItem({ title: "English" }),
    ],
  }) });
  const reply = await render(command, { query: "中文" });
  assert.deepEqual(reply.rows.map(({ section, title, markdown }) => ({ section, title, markdown })), [
    { section: "Languages", title: "中文", markdown: "Chinese" },
  ]);
});

test("randomId exposes the same URL-safe generator in view and no-view adapters", () => {
  assert.equal(randomId, noViewRandomId);
  const ids = Array.from({ length: 64 }, () => randomId());
  for (const id of ids) assert.match(id, /^[A-Za-z0-9_-]{21}$/);
  assert.equal(new Set(ids).size, ids.length);
  for (const size of [1, 2, 3, 4, 10, 32]) {
    const id = noViewRandomId(size);
    assert.equal(id.length, size);
    assert.match(id, /^[A-Za-z0-9_-]+$/);
  }
  assert.equal(randomId(0), "");
  assert.throws(() => randomId(-1), RangeError);
  assert.throws(() => randomId(1.5), RangeError);
  assert.throws(() => randomId(4_097), RangeError);
});
