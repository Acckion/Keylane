const { describeImage } = require("./image-api.cjs");
const { filterViewGroups, viewItemIDs, viewText: listText } = require("./view-filter.cjs");

const { builtInIcons } = require("./presentation-values.cjs");

function emptyIcon(icon) {
  const value = icon?.value ?? icon;
  const source = typeof value === "string" ? value : value?.source;
  return builtInIcons.has(source) ? source : undefined;
}

function listNodes(root, query, children) {
  const groups = [];
  let emptyProps;
  let pending = [];

  function flush() {
    if (pending.length) groups.push({ items: pending });
    pending = [];
  }

  let sectionID = 0;
  for (const node of children(root)) {
    if (node.type === "listEmpty") {
      emptyProps ??= node.props;
    } else if (node.type === "section") {
      flush();
      const { title, subtitle } = node.props;
      groups.push({ section: listText(title), sectionSubtitle: listText(subtitle),
        sectionID: sectionID++, items: children(node) });
    } else {
      pending.push(node);
    }
  }
  flush();

  if (groups.some(({ items }) => items.some((item) => item.type !== "item"))) throw new Error("Expected List.Item");
  const hasItems = groups.some(({ items }) => items.length);
  const identities = viewItemIDs(groups, root.props);
  const nodes = filterViewGroups(groups, root.props, query)
    .flatMap(({ items, ...section }) => items.map((item) => ({ item, itemID: identities.get(item), ...section })));

  if (nodes.length || (root.props.isLoading === true && !query)) return { nodes };

  const imageDescriptor = describeImage(emptyProps?.icon);
  return {
    nodes,
    empty: {
      title: listText(emptyProps?.title),
      description: listText(emptyProps?.description),
      icon: emptyIcon(emptyProps?.icon),
      ...(imageDescriptor && { imageDescriptor }),
      panel: emptyProps?.actions ?? (hasItems ? undefined : root.props.actions),
    },
  };
}

module.exports = { listNodes, listText };
