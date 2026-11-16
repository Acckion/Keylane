const { describeImage } = require("./image-api.cjs");
const { builtInIcons, colorVariants } = require("./presentation-values.cjs");
const { effectReceipt } = require("./action-api.cjs");

function listMetadataComponents(component) {
  const TagList = Object.assign(component("listMetadataTags"), { Item: component("listMetadataTag") });
  return { Link: component("listMetadataLink"), TagList };
}

function text(value) {
  return typeof value === "string" && Buffer.byteLength(value) <= 512 ? value : undefined;
}

function labelDescription(props) {
  const source = props.icon?.source ?? props.icon;
  const icon = builtInIcons.has(source) ? source : undefined;
  const imageDescriptor = describeImage(props.icon);
  const { light, dark } = colorVariants(props.text?.color);
  return {
    kind: "label", title: text(props.title), text: text(props.text?.value ?? props.text ?? ""),
    ...(icon && { icon }), ...(imageDescriptor && { imageDescriptor }),
    ...(light !== undefined && { color: light }), ...(dark !== undefined && { darkColor: dark }),
  };
}

function tagDescription(node) {
  if (node.type !== "listMetadataTag") return undefined;
  const props = node.props ?? {};
  const tagText = text(props.text);
  const source = props.icon?.source ?? props.icon;
  const icon = builtInIcons.has(source) ? source : undefined;
  const imageDescriptor = describeImage(props.icon);
  if (!tagText && !icon && !imageDescriptor) return undefined;
  const { light, dark } = colorVariants(props.color);
  return { text: tagText, icon, color: light, darkColor: dark, ...(imageDescriptor && { imageDescriptor }) };
}

function describeMetadataLink(props, validateURL) {
  const title = text(props.title);
  const label = text(props.text);
  if (title === undefined || label === undefined) return [];
  try {
    return [{ kind: "link", title, text: label, target: validateURL(props.target) }];
  } catch {
    return [{ kind: "label", title, text: label }];
  }
}

function tagEntries(node, group, children, scope) {
  const title = text(node.props?.title);
  if (title === undefined) return [];
  const entries = [];
  for (const [index, tag] of children(node).entries()) {
    const description = tagDescription(tag);
    if (!description) continue;
    const callback = tag.props.onAction;
    if (typeof callback === "function") {
      description.actionReceipt = effectReceipt([scope, group, index, title, description], {});
    }
    entries.push({ description, callback });
    if (entries.length === 24) break;
  }
  return entries;
}

function metadataTagCallback(panel, receipt, children, scope) {
  for (const [index, node] of children(panel).slice(0, 32).entries()) {
    if (node.type !== "listMetadataTags") continue;
    const match = tagEntries(node, index, children, scope).find(({ description }) => description.actionReceipt === receipt);
    if (match) return match.callback;
  }
}

function describeListMetadata(panel, children, validateURL, { includeLabelsOnly = false, scope } = {}) {
  const nodes = children(panel);
  if (!includeLabelsOnly && !nodes.some(({ type, props }) => type === "separator" || type === "listMetadataLink" ||
      type === "listMetadataTags" || (type === "label" && (props?.icon != null || props?.text?.color != null)))) return undefined;
  return nodes.slice(0, 32).flatMap((node, index) => {
    const { type, props = {} } = node;
    const title = text(props.title);
    switch (type) {
      case "label":
        return [labelDescription(props)];
      case "separator":
        return [{ kind: "separator" }];
      case "listMetadataLink":
        return describeMetadataLink(props, validateURL);
      case "listMetadataTags": {
        if (title === undefined) return [];
        const tags = tagEntries(node, index, children, scope).map(({ description }) => description);
        return [{ kind: "tags", title, tags }];
      }
      default:
        return [];
    }
  });
}

module.exports = { listMetadataComponents, describeListMetadata, describeMetadataLink, metadataTagCallback };
