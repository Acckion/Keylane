const { describeImage } = require("./image-api.cjs");
const { createHash } = require("node:crypto");
const { builtInIcons } = require("./presentation-values.cjs");

const ActionStyle = Object.freeze({ Regular: "regular", Destructive: "destructive" });

function actionPanelComponents(component) {
  return Object.assign(component("actions"), {
    Section: component("actionSection"),
    Submenu: component("actionSubmenu"),
  });
}

function actionEntries(panel, children) {
  let nextID = 0;
  const leaves = new Map();
  function visit(node, group, groupTitle, depth) {
    if (nextID >= 12 || depth > 4) throw new Error("Action panel limit exceeded");
    const id = nextID++;
    if (node.type === "actionSubmenu") {
      return { node, id, group, groupTitle, items: visitLevel(node, depth + 1) };
    }
    if (node.type === "actionSection") throw new Error("Expected an action or submenu");
    leaves.set(id, node);
    return { node, id, group, groupTitle };
  }

  function visitLevel(parent, depth) {
    const entries = [];
    let group = 0;
    let endedSection = false;
    for (const node of children(parent)) {
      const section = node.type === "actionSection";
      const items = section ? children(node) : [node];
      if (!items.length) continue;
      if (entries.length && (section || endedSection)) group++;
      const groupTitle = section && typeof node.props.title === "string" ? node.props.title : undefined;
      for (const item of items) entries.push(visit(item, group, groupTitle, depth));
      endedSection = section;
    }
    return entries;
  }

  return { entries: visitLevel(panel, 1), leaves };
}

const modifiers = new Set(["cmd", "ctrl", "opt", "shift"]);
const specialKeys = new Set([
  "return", "enter", "delete", "backspace", "deleteForward", "tab", "arrowUp", "arrowDown", "arrowLeft", "arrowRight",
  "pageUp", "pageDown", "home", "end", "space", "escape",
]);

function actionShortcut(shortcut) {
  const chord = shortcut?.macOS ?? shortcut;
  const key = chord?.key;
  const flags = chord?.modifiers;
  if (typeof key !== "string" || (!/^[a-z0-9.,;=+\[\]{}«»()/\\'`§^@$-]$/u.test(key) && !specialKeys.has(key)) ||
      !Array.isArray(flags) || flags.length > 4 || new Set(flags).size !== flags.length ||
      !flags.every((flag) => modifiers.has(flag))) return undefined;
  return { key, modifiers: flags };
}

function actionPanelTitle(panel) {
  const title = panel?.props?.title;
  return typeof title === "string" && Buffer.byteLength(title) <= 512 ? title : undefined;
}

function submenuOptions({ props }) {
  const observesSearch = typeof props.onSearchTextChange === "function";
  return {
    observesSearch,
    nativeFiltering: props.filtering === undefined ? !observesSearch : props.filtering !== false,
    keepSectionOrder: props.filtering?.keepSectionOrder === true,
    throttle: props.throttle === true,
    isLoading: props.isLoading === true,
  };
}

function checkedMenuRoute(route) {
  if (route === undefined) return [];
  if (!Array.isArray(route) || route.length > 3 || route.some((entry) =>
    !entry || !Number.isInteger(entry.index) || entry.index < 0 || entry.index >= 12 ||
    (entry.query !== undefined && (typeof entry.query !== "string" || Buffer.byteLength(entry.query) > 256)))) {
    throw new Error("Invalid action submenu route");
  }
  return route;
}

function submenuAt(panel, route, children) {
  let current = panel;
  for (const { index } of route) {
    const entry = actionEntries(current, children).entries[index];
    if (entry?.node.type !== "actionSubmenu") throw new Error("Unknown action submenu");
    current = entry.node;
  }
  return current;
}

async function replayActionMenu(route, panel, children, apply) {
  for (const [index, step] of route.entries()) {
    const path = route.slice(0, index + 1);
    const submenu = submenuAt(panel(), path, children);
    if (typeof submenu.props.onOpen === "function") await apply(submenu.props.onOpen);
    const updated = submenuAt(panel(), path, children);
    if (step.query !== undefined && typeof updated.props.onSearchTextChange === "function") {
      await apply(updated.props.onSearchTextChange, step.query);
    }
  }
  return submenuAt(panel(), route, children);
}

function describeActions(panel, children) {
  function describe({ node, id, group, groupTitle, items }) {
    const source = node.props.icon?.source ?? node.props.icon;
    const imageDescriptor = describeImage(node.props.icon);
    const icon = { ...(builtInIcons.has(source) && { icon: source }), ...(imageDescriptor && { imageDescriptor }) };
    const shortcut = actionShortcut(node.props.shortcut);
    const options = { ...(shortcut && { shortcut }), ...(node.props.autoFocus === true && { autoFocus: true }) };
    if (items) {
      const submenu = submenuOptions(node);
      const dynamic = typeof node.props.onOpen === "function" || submenu.observesSearch ||
        node.props.filtering !== undefined || node.props.isLoading !== undefined;
      return {
        id, title: node.props.title ?? "Actions", kind: "submenu", children: items.map(describe), ...icon, ...options,
        ...(dynamic && { submenu }),
        ...(group ? { group } : {}),
        ...(groupTitle !== undefined ? { groupTitle } : {}),
      };
    }
    return {
      id, title: node.props.title ?? "Copy", kind: node.type,
      destructive: node.props.style === ActionStyle.Destructive,
      ...icon, ...options,
      ...(group ? { group } : {}),
      ...(groupTitle !== undefined ? { groupTitle } : {}),
    };
  }
  return actionEntries(panel, children).entries.map(describe);
}

function findAction(panel, id, children) {
  return actionEntries(panel, children).leaves.get(id);
}

function effectReceipt(effect, { id, title }) {
  const identity = [typeof id === "string" ? id : null, typeof title === "string" ? title : null];
  return createHash("sha256").update(JSON.stringify([identity, effect])).digest("hex");
}

module.exports = {
  ActionStyle, actionPanelComponents, describeActions, findAction, actionPanelTitle,
  checkedMenuRoute, replayActionMenu, submenuOptions, effectReceipt,
};
