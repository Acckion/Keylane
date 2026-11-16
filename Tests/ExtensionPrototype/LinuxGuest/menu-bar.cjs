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

  function describe(node, depth) {
    if (++count > 64 || depth > 5) throw new Error("Menu tree limit exceeded");
    const { title, subtitle, tooltip, shortcut, onAction, icon } = node.props ?? {};
    switch (node.type) {
      case "menuSeparator":
        return { kind: "separator" };
      case "menuSection":
        return { kind: "section", title, children: children(node).map((child) => describe(child, depth + 1)) };
      case "menuSubmenu":
        return { kind: "submenu", title, icon: icon?.source ?? icon, children: children(node).map((child) => describe(child, depth + 1)) };
      case "menuItem": {
        const id = callbacks.length;
        callbacks.push(onAction);
        const chord = shortcut?.macOS ?? shortcut;
        return {
          kind: "item", id, title, subtitle, tooltip, icon: icon?.source ?? icon,
          enabled: typeof onAction === "function", key: chord?.key, modifiers: chord?.modifiers,
        };
      }
      default:
        throw new Error("Unsupported MenuBarExtra child");
    }
  }

  return { items: children(root).map((child) => describe(child, 1)), callbacks };
}

module.exports = { menuBarComponents, describeMenu };
