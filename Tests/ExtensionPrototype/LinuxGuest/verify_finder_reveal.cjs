const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  absoluteFilePath, finderRevealComponent, finderRevealEffect, makeShowInFinder,
} = require("./finder-reveal.cjs");

test("Finder reveal accepts absolute strings, file URLs and UTF-8 buffers", () => {
  const target = "/Volumes/Fixture/文件 #1.txt";
  const expected = { kind: "showInFinder", paths: [target] };
  assert.deepEqual(finderRevealEffect(target), expected);
  assert.deepEqual(finderRevealEffect(new URL("file:///Volumes/Fixture/%E6%96%87%E4%BB%B6%20%231.txt")), expected);
  assert.deepEqual(finderRevealEffect(Buffer.from(target)), expected);
  assert.equal(absoluteFilePath("/"), "/");
});

test("file requests reject unsafe paths and ambiguous URLs before emitting", async () => {
  const targets = [
    undefined, 1, ["absolute"], "relative.txt", "~/Documents", "//remote/path",
    "file:///tmp/example", "/tmp/line\nbreak", "/tmp/nul\0", "/tmp/\uD800",
    new URL("https://example.com/test"), new URL("file://remote/path"),
    new URL("file:///tmp/target?query"), new URL("file:///tmp/target#fragment"),
    new URL("file:///tmp/%2f"), Buffer.from([0x2f, 0xff]), "/" + "测".repeat(683),
  ];

  const showInFinder = makeShowInFinder(() => assert.fail("invalid path emitted an effect"));
  for (const target of targets) await assert.rejects(showInFinder(target), TypeError);
});

test("Finder action construction is inert and preserves title and path", () => {
  const ShowInFinder = finderRevealComponent((type) => (props) => ({ type, props }));
  const path = "/tmp/fixture";
  assert.deepEqual(ShowInFinder({ path }), { type: "showInFinder", props: { title: "Show in Finder", path, icon: "finder-16" } });
  assert.deepEqual(ShowInFinder({ path, title: "Reveal Fixture" }), {
    type: "showInFinder", props: { title: "Reveal Fixture", path, icon: "finder-16" },
  });
});

test("selected file actions run completion only with a receipt for their original PathLike arguments", async () => {
  const { Action, ActionPanel, Detail, render, showInFinder } = require("./view-api.cjs");
  const url = new URL("file:///tmp/Some%20File.txt");
  const buffer = Buffer.from("/tmp/测试.txt");
  const paths = [url, buffer, url];
  const calls = [];
  const view = (target = url) => () => Detail({ actions: ActionPanel({ children: [
    Action.ShowInFinder({ path: target, onShow: (original) => calls.push(original) }),
    Action.Trash({ paths, onTrash: (original) => calls.push(original) }),
    Action({ title: "Other" }),
    Action.OpenWith({ path: "/tmp/Some File.txt", onOpen: (original) => calls.push(original) }),
  ] }) });
  const event = (id, fileReceipt) => ({ action: { row: 0, id }, fileReceipt });
  const reveal = await render(view(), event(0));
  const trash = await render(view(), event(1));
  const openWith = await render(view(), event(3));
  assert.deepEqual(calls, []);
  assert.deepEqual(reveal.paths, ["/tmp/Some File.txt"]);
  assert.deepEqual(trash.paths, ["/tmp/Some File.txt", "/tmp/测试.txt"]);
  assert.match(reveal.fileReceipt, /^showInFinder:[0-9a-f]{64}$/);
  assert.match(trash.fileReceipt, /^trashFiles:[0-9a-f]{64}$/);
  assert.match(openWith.fileReceipt, /^openWith:[0-9a-f]{64}$/);
  await assert.rejects(render(view(), event(1, reveal.fileReceipt)), /Invalid file completion receipt/);
  await assert.rejects(render(view(), event(2, trash.fileReceipt)), /Invalid file completion receipt/);
  await assert.rejects(render(view(), event(3, trash.fileReceipt)), /Invalid file completion receipt/);
  await assert.rejects(render(view("/tmp/Some File.txt"), event(0, reveal.fileReceipt)), /Invalid file completion receipt/);
  const revealReply = await render(view(), event(0, reveal.fileReceipt));
  const trashReply = await render(view(), event(1, trash.fileReceipt));
  const openWithReply = await render(view(), event(3, openWith.fileReceipt));
  assert.deepEqual([revealReply, trashReply, openWithReply], Array.from({ length: 3 }, () => ({ kind: "action" })));
  assert.equal(calls[0], url);
  assert.equal(calls[1], paths);
  assert.equal(calls[2], "/tmp/Some File.txt");
  const cannotChain = () => Detail({ actions: ActionPanel({ children: Action.ShowInFinder({
    path: url, onShow: () => showInFinder(buffer),
  }) }) });
  const first = await render(cannotChain, event(0));
  await assert.rejects(render(cannotChain, event(0, first.fileReceipt)), /require a selected view action/);
});

test("imperative Finder reveal submits one effect and preserves selection errors", async () => {
  const effects = [];
  const showInFinder = makeShowInFinder((effect) => effects.push(effect));
  assert.equal(await showInFinder("/tmp/fixture"), undefined);
  assert.deepEqual(effects, [{ kind: "showInFinder", paths: ["/tmp/fixture"] }]);

  const denied = makeShowInFinder(() => { throw new Error("Requires a selected action"); });
  await assert.rejects(denied("/tmp/fixture"), /selected action/);
});
