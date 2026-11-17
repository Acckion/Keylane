const assert = require("node:assert/strict");
const test = require("node:test");
const { configureEnvironment } = require("./environment.cjs");
const { describeUtilityIcon, getAvatarIcon, getProgressIcon, makeShowFailureToast } =
  require("./utilities-visual-feedback.cjs");

const SVG_PREFIX = "data:image/svg+xml,";
const svgFor = (source) => {
  assert.ok(source.startsWith(SVG_PREFIX));
  return decodeURIComponent(source.slice(SVG_PREFIX.length));
};

test("avatar is a deterministic SVG image asset with bounded native initials", () => {
  const source = getAvatarIcon("  Émile   赵 ");
  assert.equal(source, getAvatarIcon("Émile 赵"));
  assert.match(svgFor(source), /É赵/);
  assert.match(svgFor(source), /<linearGradient/);
  const flat = getAvatarIcon("林", { background: "#13b", gradient: false });
  assert.doesNotMatch(svgFor(flat), /<linearGradient/);
  assert.deepEqual(describeUtilityIcon(flat), {
    kind: "avatar", initials: "林", startColor: "#1133bb", endColor: "#1133bb",
  });
  const escaped = svgFor(getAvatarIcon("<example &someone", { background: '" onclick="alert(1)' }));
  assert.match(escaped, />&lt;&amp;<\/text>/);
  assert.doesNotMatch(escaped, /onclick/);
  assert.equal(describeUtilityIcon("data:image/svg+xml,%3Cscript%3E"), undefined);
});

test("progress icon reflects completion and appearance in the SVG and native descriptor", () => {
  configureEnvironment({ appearance: "light" });
  const source = getProgressIcon(0.25, "raycast-purple", { backgroundOpacity: 0.5 });
  assert.match(svgFor(source), /stroke-dasharray="0\.25 1"/);
  assert.deepEqual(describeUtilityIcon(source), {
    kind: "progress", fraction: 0.25, foreground: "#9661dc", background: "#000000", opacity: 0.5,
  });
  configureEnvironment({ appearance: "dark" });
  assert.equal(describeUtilityIcon(getProgressIcon(-1)).fraction, 0);
  assert.equal(describeUtilityIcon(getProgressIcon(0)).background, "#ffffff");
  assert.doesNotMatch(svgFor(getProgressIcon(2)), /stroke-dasharray/);
  assert.equal(describeUtilityIcon(getProgressIcon(2)).fraction, 1);
  configureEnvironment(undefined);
});

test("utility assets preserve alpha, color appearance, and Unicode initials through menu icons", async () => {
  const api = require("./view-api.cjs");
  const { Color } = api;
  configureEnvironment({ appearance: "light" });
  const light = getProgressIcon(0.5, Color.Brown, { background: "#3a8c", backgroundOpacity: 0.4 });
  configureEnvironment({ appearance: "dark" });
  const dark = getProgressIcon(0.5, Color.Brown, { background: "#3a8c", backgroundOpacity: 0.4 });
  const avatar = getAvatarIcon("👩‍💻 张", { background: "#1b38" });
  const asset = describeUtilityIcon(avatar);
  assert.equal(asset.initials, "👩‍💻张");
  assert.notEqual(asset.startColor, asset.endColor);
  assert.ok([asset.startColor, asset.endColor].every((color) => color.endsWith("88")));
  assert.equal(describeUtilityIcon(light).foreground, Color.Brown.light);
  assert.equal(describeUtilityIcon(dark).foreground, Color.Brown.dark.toLowerCase());
  assert.equal(describeUtilityIcon(light).background, "#33aa88cc");
  assert.equal(describeUtilityIcon(light).opacity, 0.4);
  const menu = await api.runMenuBar(() => api.MenuBarExtra({
    icon: { source: { light, dark } },
    children: api.MenuBarExtra.Item({ title: "Owner", icon: avatar }),
  }), { wallTime: 1 });
  assert.equal(menu.imageDescriptor.light.utility.foreground, Color.Brown.light);
  assert.equal(menu.imageDescriptor.dark.utility.foreground, Color.Brown.dark.toLowerCase());
  assert.deepEqual(menu.items[0].imageDescriptor.light.utility, asset);
});

test("generated icons survive cache storage and creation of more than 256 icons", () => {
  const original = getAvatarIcon("Retained entry", { background: "#012345", gradient: false });
  for (let value = 1; value <= 300; value++) getProgressIcon(value / 1000, "#ffffff");
  const restored = JSON.parse(JSON.stringify(original));
  assert.equal(describeUtilityIcon(restored).initials, "RE");
  const { execFileSync } = require("node:child_process");
  const script = "const { describeUtilityIcon } = require(process.argv[1]); " +
    "process.stdout.write(JSON.stringify(describeUtilityIcon(process.argv[2])));";
  const fresh = JSON.parse(execFileSync(process.execPath, [
    "-e", script, require.resolve("./utilities-visual-feedback.cjs"), restored,
  ], { encoding: "utf8" }));
  assert.deepEqual(fresh, { kind: "avatar", initials: "RE", startColor: "#012345", endColor: "#012345" });

  const tampered = SVG_PREFIX + encodeURIComponent(svgFor(original).replace("</svg>", "<script/></svg>"));
  assert.equal(describeUtilityIcon(tampered), undefined);
  assert.equal(describeUtilityIcon(original + "%"), undefined);
});

test("failure toast forwards default errors, explicit overrides, and the existing return value", async () => {
  const options = [];
  const toast = { id: "existing-toast" };
  const failure = makeShowFailureToast(() => ({
    Toast: { Style: { Failure: "FAILURE" } },
    showToast: async (value) => {
      options.push(value);
      return toast;
    },
  }));
  assert.equal(await failure(new Error("连接失败")), toast);
  assert.equal(options[0].style, "FAILURE");
  assert.equal(options[0].title, "Something went wrong");
  assert.equal(options[0].message, "连接失败");
  assert.equal(options[0].primaryAction.title, "Copy Logs");
  assert.equal(options[0].secondaryAction, undefined);
  const primaryAction = { title: "Retry", onAction: () => {} };
  await failure(42, { title: "Import failed", primaryAction, message: "Try again" });
  assert.equal(options[1].style, "FAILURE");
  assert.equal(options[1].title, "Import failed");
  assert.equal(options[1].message, "Try again");
  assert.equal(options[1].primaryAction, primaryAction);
  assert.equal(options[1].secondaryAction.title, "Copy Logs");
  await failure(42);
  assert.equal(options[2].message, "42");
});

test("real Grid and failure feedback use the utilities adapter", async () => {
  const api = require("./view-api.cjs");
  const { utilitiesFor } = require("./raycast-utils.cjs");
  const utils = utilitiesFor(() => api);
  const avatar = utils.getAvatarIcon("宋 林");
  const command = () => api.Grid({ children: [
    api.Grid.Item({ title: "Avatar", content: avatar }),
    api.Grid.Item({
      title: "Progress",
      content: { source: utils.getProgressIcon(0.63) },
      actions: api.ActionPanel({
        children: api.Action({ title: "Fail", onAction: () => utils.showFailureToast("连接失败") }),
      }),
    }),
  ] });
  const view = await api.render(command, {});
  const [avatarItem, progressItem] = view.grid.sections[0].items;
  assert.equal(avatarItem.imageDescriptor.light.utility.initials, "宋林");
  assert.equal(progressItem.imageDescriptor.light.utility.fraction, 0.63);
  assert.deepEqual(await api.render(command, { action: { row: 1, id: 0 } }),
    { kind: "toast", toastStyle: "FAILURE", text: "Something went wrong 连接失败",
      feedbackAction: { kind: "copyLogs", value: "连接失败" } });
});

test("List item icons carry native utility descriptors and common image styling", async () => {
  const api = require("./view-api.cjs");
  const avatar = getAvatarIcon("张 三");
  const reply = await api.render(() => api.List({ children: [
    api.List.Item({ title: "Avatar", icon: { source: avatar, mask: "circle", tintColor: { light: "#00ff00", dark: "#00ff00", adjustContrast: false } } }),
    api.List.Item({ title: "Ordinary", icon: api.Icon.Folder }),
  ] }), {});
  assert.equal(reply.rows[0].imageDescriptor.light.utility.initials, "张三");
  assert.equal(reply.rows[0].imageDescriptor.mask, "circle");
  assert.equal(reply.rows[0].imageDescriptor.tintColor, "#00ff00");
  assert.equal(reply.rows[0].icon, undefined);
  assert.equal(reply.rows[1].icon, api.Icon.Folder);
});

test("generated icons share themed sources, fallbacks and all common image consumers", async () => {
  const api = require("./view-api.cjs");
  const { describeImage } = require("./image-api.cjs");
  const light = getAvatarIcon("林 安");
  const dark = getProgressIcon(0.5);
  const icon = { source: { light, dark }, fallback: getProgressIcon(0.25), mask: "circle" };
  const expected = describeImage(icon);
  assert.equal(expected.light.utility.initials, "林安");
  assert.equal(expected.dark.utility.fraction, 0.5);
  assert.equal(expected.fallbackLight.utility.fraction, 0.25);
  assert.equal(expected.mask, "circle");

  const reply = await api.render(() => api.Detail({
    metadata: api.Detail.Metadata({ children: api.Detail.Metadata.Label({ title: "Owner", icon }) }),
    actions: api.ActionPanel({ children: api.Action({ title: "Update", icon, onAction() {} }) }),
  }), {});
  assert.deepEqual(reply.detail.metadata[0].imageDescriptor, expected);
  assert.deepEqual(reply.detail.actions[0].imageDescriptor, expected);

  const list = await api.render(() => api.List({ children: api.List.EmptyView({ title: "Empty", icon }) }), {});
  assert.deepEqual(list.empty.imageDescriptor, expected);
  assert.equal(describeImage("data:image/svg+xml,%3Cscript%3E"), undefined);
});

test("failure diagnostics copy local logs or open a draft for public metadata", async () => {
  const fs = require("node:fs/promises");
  const root = await fs.mkdtemp(require("node:path").join(require("node:os").tmpdir(), "failure-toast-"));
  const assetsPath = root + "/assets";
  await fs.mkdir(assetsPath);
  const events = [];
  let isDevelopment = false;
  let shown;
  const failure = makeShowFailureToast(() => ({
    environment: { assetsPath, isDevelopment },
    Toast: { Style: { Failure: "FAILURE" } },
    showToast: async (options) => { shown = options; },
    Clipboard: { async copy(text) { events.push(text); } },
    async open(url) { events.push(url); },
  }));
  const toast = { async hide() { events.push("hidden"); } };
  try {
    await fs.writeFile(root + "/package.json", JSON.stringify({ owner: "org", name: "private", title: "Private" }));
    await failure("私有错误");
    assert.equal(shown.primaryAction.title, "Copy Logs");
    await shown.primaryAction.onAction(toast);
    assert.deepEqual(events.splice(0), ["hidden", "私有错误"]);
    await fs.writeFile(root + "/package.json", JSON.stringify({
      owner: "org", name: "public", title: "Public", access: "public",
    }));
    await failure("公开错误");
    assert.equal(shown.primaryAction.title, "Report Error");
    assert.deepEqual(events, []);
    await shown.primaryAction.onAction(toast);
    assert.equal(events.shift(), "hidden");
    const target = new URL(events.shift());
    assert.equal(target.origin + target.pathname, "https://github.com/raycast/extensions/issues/new");
    assert.equal(target.searchParams.get("extension-url"), "https://raycast.com/org/public");
    assert.match(target.searchParams.get("description"), /公开错误/);
    isDevelopment = true;
    await failure("长".repeat(4000));
    assert.equal(shown.primaryAction.title, "Copy Logs");
    assert.ok(Buffer.byteLength(shown.title) + Buffer.byteLength(shown.message) <= 2048);
    assert.ok(!shown.message.endsWith("\uFFFD"));
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});
