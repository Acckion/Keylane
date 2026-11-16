const { describeImage } = require("./image-api.cjs");
const { describeUtilityIcon } = require("./utilities-visual-feedback.cjs");
const { colorVariants, iconTint } = require("./presentation-values.cjs");
const { filterViewGroups, viewItemIDs } = require("./view-filter.cjs");

function gridComponents(component) {
  return Object.assign(component("grid"), {
    Item: component("gridItem"),
    Section: component("gridSection"),
    EmptyView: component("gridEmpty"),
    Inset: Object.freeze({ Zero: "zero", Small: "sm", Medium: "md", Large: "lg" }),
    ItemSize: Object.freeze({ Small: "small", Medium: "medium", Large: "large" }),
    Fit: Object.freeze({ Contain: "contain", Fill: "fill" }),
  });
}

function gridNodes(root, query, children) {
  const sections = [];
  let pending = [];
  const flush = () => {
    if (pending.length) sections.push({ items: pending });
    pending = [];
  };
  let empty;
  for (const node of children(root)) {
    if (node.type === "gridEmpty") {
      empty ??= node.props;
    } else if (node.type === "gridSection") {
      flush();
      const { title, subtitle, columns, aspectRatio, inset, fit } = node.props;
      sections.push({ title, subtitle, columns, aspectRatio, inset, fit, items: children(node) });
    } else {
      pending.push(node);
    }
  }
  flush();
  let count = 0;
  if (sections.some(({ items }) => items.some((item) => item.type !== "gridItem"))) throw new Error("Expected Grid.Item");
  const identities = viewItemIDs(sections, root.props);
  const groups = filterViewGroups(sections, root.props, query).flatMap(({ items, ...section }) => {
    const visible = items.map((item) => ({ id: count++, item, itemID: identities.get(item) }));
    return visible.length ? [{ ...section, items: visible }] : [];
  });
  if (count > 128) throw new Error("Grid item limit exceeded");
  if (count || (root.props.isLoading === true && !query)) return { groups };
  return { groups, empty: { ...empty, panel: empty?.actions ?? root.props.actions } };
}

function gridContent(content) {
  const value = content?.value ?? content;
  const source = value?.source ?? value;
  const imageDescriptor = describeImage(value);
  if (typeof source === "string") {
    const utilityIcon = describeUtilityIcon(source);
    if (utilityIcon) return { utilityIcon };
    const inline = /^data:image\/(png|jpeg);base64,/.test(source);
    if (inline && source.length <= 4096) {
      return imageDescriptor && (value?.mask || value?.fallback || value?.tintColor)
        ? { imageDescriptor } : { image: source };
    }
    const assetReference = source.includes("/") || /^(?:[a-z]+:)|\.(?:png|jpe?g|webp|gif|svg|ico|icns)$/i.test(source);
    if (!inline && !assetReference && source.length <= 128) return { glyph: source, ...iconTint(source, value?.tintColor), ...(imageDescriptor && { imageDescriptor }) };
  }
  if (imageDescriptor) return { imageDescriptor };
  const { light, dark } = colorVariants(value?.color);
  if (light !== undefined || dark !== undefined) return { color: light, ...(dark === undefined ? {} : { darkColor: dark }) };
  return {};
}

function describeGrid(root, groups, empty, describeActions, panelTitle) {
  const { columns, itemSize, navigationTitle, isLoading, inset, fit, aspectRatio } = root.props;
  const legacyColumns = { small: 8, medium: 5, large: 3 };
  return {
    columns: columns ?? legacyColumns[itemSize] ?? 5, navigationTitle, isLoading, inset, fit, aspectRatio,
    sections: groups.map(({ items, ...section }, id) => ({
      id, ...section,
      items: items.map(({ id, itemID, item: { props } }) => ({
        id, title: props.title, subtitle: props.subtitle,
        ...(itemID !== undefined && { itemID }),
        ...gridContent(props.content), actions: describeActions(props.actions), actionPanelTitle: panelTitle(props.actions),
      })),
    })),
    empty: empty && { title: empty.title, description: empty.description, ...gridContent(empty.icon) },
    actions: empty ? describeActions(empty.panel) : [],
    actionPanelTitle: empty ? panelTitle(empty.panel) : undefined,
  };
}

module.exports = { gridComponents, gridNodes, describeGrid };
