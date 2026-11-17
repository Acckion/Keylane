const { describeImage } = require("./image-api.cjs");

function describeMenuIcon(icon) {
  const source = icon?.source ?? icon;
  const imageDescriptor = describeImage(icon);
  return {
    ...(!imageDescriptor && typeof source === "string" && /^[a-z0-9-]{1,128}$/i.test(source) && { icon: source }),
    ...(imageDescriptor && { imageDescriptor }),
  };
}

function menuBarComponents(component) {
  return Object.assign(component("menuBar"), {
    Item: component("menuItem"),
    Section: component("menuSection"),
    Submenu: component("menuSubmenu"),
    Separator: component("menuSeparator"),
  });
}

function describeMenu(root, children) {
  const callbacks = [];
  let count = 0;

  function describeChildren(node, depth) {
    return children(node).flatMap((child) => describe(child, depth));
  }

  function describe(node, depth, inheritedShortcut) {
    if (++count > 64 || depth > 5) throw new Error("Menu tree limit exceeded");
    const { title, subtitle, tooltip, shortcut, onAction, icon, alternate } = node.props ?? {};
    switch (node.type) {
      case "menuSeparator":
        return [{ kind: "separator" }];
      case "menuSection":
        return [{ kind: "section", title, children: describeChildren(node, depth + 1) }];
      case "menuSubmenu":
        return [{ kind: "submenu", title, ...describeMenuIcon(icon), children: describeChildren(node, depth + 1) }];
      case "menuItem": {
        const id = callbacks.length;
        callbacks.push(onAction);
        const chord = inheritedShortcut ?? shortcut?.macOS ?? shortcut;
        const item = {
          kind: "item", id, title, subtitle, tooltip, ...describeMenuIcon(icon),
          enabled: typeof onAction === "function", key: chord?.key, modifiers: chord?.modifiers,
          ...(inheritedShortcut && { isAlternate: true }),
        };
        if (alternate == null || alternate === false) return [item];
        const modifiers = chord?.modifiers ?? (chord?.key ? ["cmd"] : []);
        if (alternate.type !== "menuItem" || alternate.props?.alternate != null ||
            alternate.props?.shortcut != null || modifiers.includes("opt")) {
          throw new Error("Invalid menu item alternate");
        }
        return [item, ...describe(alternate, depth, { key: chord?.key, modifiers: [...modifiers, "opt"] })];
      }
      default:
        throw new Error("Unsupported MenuBarExtra child");
    }
  }

  return { items: describeChildren(root, 1), callbacks };
}

module.exports = { menuBarComponents, describeMenu, describeMenuIcon };
