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

test("rendering descriptors are limited to the current guest's generated assets", () => {
  const evicted = getAvatarIcon("Evicted entry", { background: "#012345", gradient: false });
  for (let value = 1; value <= 256; value++) getProgressIcon(value / 1000, "#ffffff");
  assert.equal(describeUtilityIcon(evicted), undefined);
  assert.equal(describeUtilityIcon(getProgressIcon(0.256, "#ffffff")).kind, "progress");
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
  assert.deepEqual(options[0], { style: "FAILURE", title: "Something went wrong", message: "连接失败", primaryAction: undefined });
  const primaryAction = { title: "Retry", onAction: () => {} };
  await failure(42, { title: "Import failed", primaryAction, message: "Try again" });
  assert.deepEqual(options[1], { style: "FAILURE", title: "Import failed", message: "Try again", primaryAction });
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
  assert.equal(avatarItem.utilityIcon.initials, "宋林");
  assert.equal(progressItem.utilityIcon.fraction, 0.63);
  assert.deepEqual(await api.render(command, { action: { row: 1, id: 0 } }),
    { kind: "error", text: "Something went wrong 连接失败" });
});

test("List item icons carry native utility descriptors beside ordinary symbols", async () => {
  const api = require("./view-api.cjs");
  const avatar = getAvatarIcon("张 三");
  const reply = await api.render(() => api.List({ children: [
    api.List.Item({ title: "Avatar", icon: { source: avatar } }),
    api.List.Item({ title: "Ordinary", icon: api.Icon.Folder }),
  ] }), {});
  assert.equal(reply.rows[0].utilityIcon.initials, "张三");
  assert.equal(reply.rows[0].icon, undefined);
  assert.equal(reply.rows[1].icon, api.Icon.Folder);
});
