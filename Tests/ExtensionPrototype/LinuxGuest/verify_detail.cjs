const assert = require("node:assert/strict");
const test = require("node:test");
const { Action, ActionPanel, Detail, List, render } = require("./view-api.cjs");

const { Metadata } = Detail;
const command = () => Detail({
  markdown: "**Hello** _详情_",
  navigationTitle: "Preview",
  isLoading: true,
  metadata: Metadata({ children: [
    Metadata.Label({ title: "Version", text: { value: "1.0" } }),
    Metadata.Separator({}),
    Metadata.TagList({ title: "Tags", children: [
      Metadata.TagList.Item({ text: "Swift", color: { light: "#abc", dark: "#123456", adjustContrast: false } }),
      Metadata.TagList.Item({ icon: "Folder" }),
    ] }),
    Metadata.TagList({ title: "Empty", children: null }),
  ] }),
  actions: ActionPanel({ children: [
    Action.CopyToClipboard({ title: "Copy", content: "sample" }),
    Action({ title: "Run", style: Action.Style.Destructive, onAction: () => {} }),
  ] }),
});

test("standalone detail renders its document, metadata and actions", async () => {
  const { kind, detail } = await render(command, {});
  assert.equal(kind, "detail");
  assert.equal(detail.markdown, "**Hello** _详情_");
  assert.equal(detail.navigationTitle, "Preview");
  assert.equal(detail.isLoading, true);
  assert.deepEqual(JSON.parse(JSON.stringify(detail.metadata)), [
    { kind: "label", title: "Version", text: "1.0" },
    { kind: "separator" },
    { kind: "tags", title: "Tags", tags: [
      { text: "Swift", color: "#abc", darkColor: "#123456" },
      { icon: "Folder" },
    ] },
    { kind: "tags", title: "Empty", tags: [] },
  ]);
  assert.deepEqual(detail.actions.map(({ id, kind, destructive }) => [id, kind, destructive]), [
    [0, "copy", false], [1, "callback", true],
  ]);
});

test("detail actions share the view action flow", async () => {
  assert.deepEqual(await render(command, { action: { row: 0, id: 0 } }), { kind: "copy", text: "sample" });
  assert.deepEqual(await render(command, { action: { row: 0, id: 1 } }), { kind: "action" });
  await assert.rejects(render(command, { action: { row: 1, id: 0 } }), /Unknown detail/);
});

test("list row detail retains its existing wire format", async () => {
  const { Detail: RowDetail } = List.Item;
  const result = await render(() => List({ isShowingDetail: true, children: List.Item({
    title: "Row",
    detail: RowDetail({
      markdown: "old view",
      metadata: RowDetail.Metadata({ children: RowDetail.Metadata.Label({ title: "One", text: "Two" }) }),
    }),
  }) }), {});
  assert.equal(result.kind, "view");
  assert.equal(result.rows[0].markdown, "old view");
  assert.deepEqual(result.rows[0].metadata, [{ title: "One", text: "Two" }]);
});

test("standalone and list detail Markdown carry generated images as typed references", async () => {
  const { getAvatarIcon, getProgressIcon } = require("./utilities-visual-feedback.cjs");
  const avatar = getAvatarIcon("林 安");
  const progress = getProgressIcon(0.7);
  const markdown = [
    "![Avatar](" + avatar + ")",
    '![Progress](<' + progress + '> "70 percent")',
    "![Repeat](" + avatar + ")",
    "![Remote](https://example.invalid/i.svg)",
  ].join("\n\n");
  const expected = [
    "![Avatar](keylane-image://icon/0)",
    '![Progress](<keylane-image://icon/1> "70 percent")',
    "![Repeat](keylane-image://icon/0)",
    "![Remote](keylane-image://icon/2)",
  ].join("\n\n");
  const standalone = await render(() => Detail({ markdown }), {});
  const list = await render(() => List({ isShowingDetail: true, children: List.Item({
    title: "Row", detail: List.Item.Detail({ markdown }),
  }) }), {});
  for (const result of [standalone.detail, list.rows[0]]) {
    assert.equal(result.markdown, expected);
    assert.equal(result.markdownImages[0].light.utility.initials, "林安");
    assert.equal(result.markdownImages[1].light.utility.fraction, 0.7);
  }
  const literal = "`![Sample](" + avatar + ")`";
  const code = await render(() => Detail({ markdown: literal }), {});
  assert.equal(code.detail.markdown, literal);
  assert.equal(code.detail.markdownImages, undefined);
});

test("Markdown symbols and rasters share the view image budget", async () => {
  const { Icon } = require("./view-api.cjs");
  const { limitImagePayloads } = require("./image-api.cjs");
  const first = "data:image/png;base64," + "A".repeat(2400);
  const second = "data:image/png;base64," + "B".repeat(2400);
  const markdown = [
    `![Folder](${Icon.Folder})`,
    `![First](${first})`,
    `![Second](${second})`,
    "![Traversal](%2e%2e%2fprivate.png)",
    "![Remote](https://example.invalid/image.png)",
    "![Invalid](%ZZ.png)",
  ].join("\n");
  const { detail } = limitImagePayloads(await render(() => Detail({ markdown }), {}));
  assert.deepEqual(detail.markdownImages.map((image) => image.light?.symbol ?? image.light?.raster), [
    Icon.Folder, first, undefined, undefined,
  ]);
  assert.match(detail.markdown, /!\[Second\]\(keylane-image:\/\/icon\/2\)/);
  assert.match(detail.markdown, /%2e%2e%2fprivate\.png/);
  assert.equal(detail.markdownImages[3].light.remoteURL, "https://example.invalid/image.png");
  assert.match(detail.markdown, /!\[Remote\]\(keylane-image:\/\/icon\/3\)/);
  assert.match(detail.markdown, /%ZZ\.png/);
});

test("Markdown image options share sources across sizes and normalize tint", async () => {
  const { Icon } = require("./view-api.cjs");
  const { getProgressIcon } = require("./utilities-visual-feedback.cjs");
  const icon = Icon.Folder;
  const progress = getProgressIcon(0.25);
  const markdown = [
    `![Small](${icon}?raycast-width=20&raycast-height=12.5)`,
    `![Wide](<${icon}?raycast-width=150> "Large")`,
    `![Tint](${icon}?raycast-tintColor=blue)`,
    `![Tint again](${icon}?raycast-tint-color=blue&raycast-height=32)`,
    `![Invalid size](${icon}?raycast-width=1e10&raycast-height=0)`,
    `![Progress](${progress}?raycast-width=28)`,
    "![Remote](https://example.invalid/icon.png?raycast-width=24)",
  ].join("\n");
  const { detail } = await render(() => Detail({ markdown }), {});
  assert.deepEqual(detail.markdown.split("\n"), [
    "![Small](keylane-image://icon/0?width=20&height=12.5)",
    '![Wide](<keylane-image://icon/0?width=150> "Large")',
    "![Tint](keylane-image://icon/1)",
    "![Tint again](keylane-image://icon/1?height=32)",
    "![Invalid size](keylane-image://icon/0)",
    "![Progress](keylane-image://icon/2?width=28)",
    "![Remote](keylane-image://icon/3?width=24)",
  ]);
  assert.equal(detail.markdownImages[1].light.symbol, icon);
  assert.equal(detail.markdownImages[1].tintColor, "#0000ff");
  assert.equal(detail.markdownImages[2].light.utility.fraction, 0.25);
});

test("reference images carry reviewed destinations without changing shared links or code", async () => {
  const { createHash } = require("node:crypto");
  const { Icon } = require("./view-api.cjs");
  const target = Icon.Folder + "?raycast-width=40&raycast-height=24";
  const markdown = [
    "![Shown][ A  Label ]",
    "",
    "![A label][]",
    "",
    "![A label]",
    "",
    "[Shared reference][a label]",
    "",
    "[a label]: <" + target.replace("&", "&amp;") + "> 'Optional title'",
    "",
    "> ![Quoted][q]",
    ">",
    "> [q]:",
    ">   " + Icon.Checkmark,
    "",
    "~~~",
    "![Fake][fake]",
    "[fake]: " + Icon.Person,
    "~~~",
    "",
    "![External][remote]",
    "[remote]: https://example.invalid/folder.png",
  ].join("\n");
  const digest = (source) => createHash("sha256").update(source).digest("hex");
  const { detail } = await render(() => Detail({ markdown }), {});
  assert.equal(detail.markdown, markdown);
  assert.deepEqual({ ...detail.markdownImageReferences }, {
    [digest(target)]: "keylane-image://icon/0?width=40&height=24",
    [digest(Icon.Checkmark)]: "keylane-image://icon/1",
    [digest("https://example.invalid/folder.png")]: "keylane-image://icon/2",
  });
  assert.deepEqual(detail.markdownImages.map((image) => image.light?.symbol), [Icon.Folder, Icon.Checkmark, undefined]);
  assert.equal(detail.markdownImages[2].light.remoteURL, "https://example.invalid/folder.png");
});

test("remote Markdown images preserve signed query bytes and consume only display options", async () => {
  const resource = "https://example.invalid/assets/a%20b.png?sig=a%2fb+%7E&raw=%20";
  const alternate = resource.replace("%2f", "/");
  const markdown = [
    `![First](${resource}&raycast-width=42#heading)`,
    `![Second](${resource}&raycast-height=17)`,
    "![Untrusted](http://example.invalid/not-https.png)",
    "![Credentials](https://user@example.invalid/private.png)",
    "",
    "![Same escape][a] ![Different escape][b]",
    `[a]: <${resource}&raycast-height=18>`,
    `[b]: <${alternate}>`,
  ].join("\n");
  const { detail } = await render(() => Detail({ markdown }), {});
  assert.deepEqual(detail.markdownImages.map((image) => image.light.remoteURL), [resource, alternate]);
  assert.equal(Object.keys(detail.markdownImageReferences).length, 2);
  assert.match(detail.markdown, /keylane-image:\/\/icon\/0\?width=42/);
  assert.match(detail.markdown, /keylane-image:\/\/icon\/0\?height=17/);
  assert.match(detail.markdown, /http:\/\/example\.invalid\/not-https\.png/);
  assert.match(detail.markdown, /https:\/\/user@example\.invalid/);
});

test("awaited effects publish a bounded loading view before the final snapshot", async () => {
  const { Action, ActionPanel, Detail, Grid, List, render, useEffect, useState } = require("./view-api.cjs");
  const actions = ActionPanel({ children: Action.CopyToClipboard({ content: "final action" }) });
  const components = [
    [(loaded) => Detail({ markdown: loaded ? "Done" : "Loading", isLoading: !loaded, actions }),
      (view) => [view.detail.isLoading, view.detail.actions.length]],
    [(loaded) => List({ isShowingDetail: true, children: List.Item({
      title: "Row", actions, detail: List.Item.Detail({ isLoading: !loaded, markdown: loaded ? "Done" : "Loading" }),
    }) }), (view) => [view.rows[0].detailLoading === true, view.rows[0].actions.length]],
    [(loaded) => Grid({ isLoading: !loaded, actions }), (view) => [view.grid.isLoading, view.grid.actions.length]],
  ];
  for (const [component, properties] of components) {
    let finish;
    let progressCount = 0;
    const release = new Promise((resolve) => { finish = resolve; });
    const result = await render(() => {
      const [loaded, setLoaded] = useState(false);
      useEffect(async () => {
        await release;
        setLoaded(true);
      });
      return component(loaded);
    }, { query: "" }, {
      async publish(preview) {
        try {
          progressCount++;
          assert.deepEqual(properties(preview), [true, 0]);
        } finally {
          finish();
        }
      },
    });
    assert.equal(progressCount, 1);
    assert.deepEqual(properties(result), [false, 1]);
  }
});

test("fast effects do not flash a loading view", async () => {
  const { Detail, render, useEffect, useState } = require("./view-api.cjs");
  const result = await render(() => {
    const [loaded, setLoaded] = useState(false);
    useEffect(async () => {
      await Promise.resolve();
      setLoaded(true);
    });
    return Detail({ markdown: "Detail", isLoading: !loaded });
  }, {}, { publish: assert.fail });
  assert.equal(result.detail.isLoading, false);
});

test("a one-shot guest publishes detached timer changes before exiting", () => {
  const { execFileSync } = require("node:child_process");
  const output = execFileSync(process.execPath, ["-e", `
    const { Detail, render, useEffect, useState } = require("./view-api.cjs");
    let loading = false;
    render(() => {
      const [text, setText] = useState("loading");
      useEffect(() => { setTimeout(() => setText("finished"), 300); });
      return Detail({ markdown: text, isLoading: text === "loading" });
    }, {}, {
      drain: () => new Promise((resolve) => process.once("beforeExit", resolve)),
      publish: async (view) => { loading = view.detail.markdown === "loading"; },
    }).then((view) => console.log(JSON.stringify([loading, view.detail.markdown])));
  `], { cwd: __dirname, encoding: "utf8", timeout: 3000 });
  assert.deepEqual(JSON.parse(output), [true, "finished"]);
});

test("view updates coalesce synchronous changes and reserve a final snapshot", async () => {
  const { Detail, render, useEffect, useState } = require("./view-api.cjs");
  const previews = [];
  let update;
  let finish;
  const release = new Promise((resolve) => { finish = resolve; });
  const result = await render(() => {
    const [text, setText] = useState("initial");
    update = setText;
    useEffect(async () => {
      await release;
      setText("final");
    });
    return Detail({ markdown: text, isLoading: text !== "final" });
  }, {}, {
    async publish(view) {
      previews.push(view.detail.markdown);
      update("discard " + previews.length);
      update("batch " + previews.length);
      update("batch " + previews.length);
      if (previews.length === 4) finish();
    },
  });
  assert.deepEqual(previews, ["initial", "batch 1", "batch 2", "batch 3"]);
  assert.equal(result.detail.markdown, "final");
  assert.equal(result.detail.isLoading, false);
});
