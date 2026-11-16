const { describeImage } = require("./image-api.cjs");
const { builtInIcons } = require("./presentation-values.cjs");
const maximumSections = 32;
const maximumItems = 64;

function dropdownComponent(component) {
  return Object.assign(component("viewDropdown"), {
    Item: component("viewDropdownItem"),
    Section: component("viewDropdownSection"),
  });
}

function validString(value, bytes) {
  return typeof value === "string" && Buffer.byteLength(value) <= bytes;
}

function dropdownSearchHandler(root) {
  const dropdown = root?.props?.searchBarAccessory;
  const handler = dropdown?.type === "viewDropdown" ? dropdown.props.onSearchTextChange : undefined;
  return typeof handler === "function" ? handler : undefined;
}

function describeDropdown(root, children, selection, previousItem) {
  const dropdown = root?.props?.searchBarAccessory;
  if (dropdown?.type !== "viewDropdown") return undefined;
  const { tooltip, placeholder, value, defaultValue, id, storeValue, filtering, isLoading, throttle } = dropdown.props;
  const seen = new Set();
  const sections = [];

  function item(node) {
    if (node.type !== "viewDropdownItem") throw new Error("Invalid dropdown item");
    const { value, title, icon, keywords } = node.props;
    if (!validString(value, 256) || !validString(title, 256) || seen.has(value) || seen.size >= maximumItems) {
      throw new Error("Invalid dropdown item value or title");
    }
    seen.add(value);
    const source = icon?.source ?? icon;
    const words = Array.isArray(keywords) ? keywords.filter((word) => validString(word, 128)).slice(0, 8) : undefined;
    const imageDescriptor = describeImage(icon);
    return { value, title, icon: builtInIcons.has(source) ? source : undefined, keywords: words, ...(imageDescriptor && { imageDescriptor }) };
  }

  let ungrouped = [];
  function flush() {
    if (!ungrouped.length) return;
    sections.push({ items: ungrouped });
    ungrouped = [];
  }
  for (const node of children(dropdown)) {
    if (node.type === "viewDropdownSection") {
      flush();
      const title = validString(node.props.title, 256) ? node.props.title : undefined;
      const items = children(node).map(item);
      if (items.length) sections.push({ title, items });
    } else {
      ungrouped.push(item(node));
    }
  }
  flush();
  if (sections.length > maximumSections) throw new Error("Dropdown section limit exceeded");
  const selected = [value, selection, defaultValue].find((candidate) =>
    seen.has(candidate) || (candidate !== undefined && candidate === previousItem?.value)) ?? seen.values().next().value;
  const observesSearch = dropdownSearchHandler(root) !== undefined;
  const storageID = storeValue === true && (id === undefined || validString(id, 256))
    ? (id === undefined ? "default" : `id:${id}`) : undefined;
  return {
    tooltip: validString(tooltip, 256) ? tooltip : undefined,
    placeholder: validString(placeholder, 256) ? placeholder : undefined,
    selected,
    selectedItem: selected !== undefined && !seen.has(selected) ? previousItem : undefined,
    storageID,
    observesSearch,
    nativeFiltering: filtering !== undefined ? filtering !== false : !observesSearch,
    keepSectionOrder: filtering?.keepSectionOrder === true,
    isLoading: isLoading === true,
    throttle: throttle === true,
    sections,
  };
}

async function applyDropdownSelection(root, children, value, { strict = true, previousValue } = {}) {
  const dropdown = describeDropdown(root, children);
  if (!validString(value, 256) || !dropdown?.sections.some(({ items }) => items.some((item) => item.value === value))) {
    if (strict) throw new Error("Invalid dropdown selection");
    return false;
  }
  const { onChange } = root.props.searchBarAccessory.props;
  if (value !== (previousValue ?? dropdown.selected) && typeof onChange === "function") await onChange(value);
  return true;
}

function restoredDropdownValue(dropdown, preferences) {
  if (dropdown?.storageID === undefined || !Array.isArray(preferences) || preferences.length > 4) return undefined;
  const pair = preferences.find((entry) => Array.isArray(entry) && entry.length === 2 && entry[0] === dropdown.storageID);
  const value = pair?.[1];
  return validString(value, 256) && dropdown.sections.some(({ items }) => items.some((item) => item.value === value))
    ? value : undefined;
}

module.exports = { dropdownComponent, describeDropdown, applyDropdownSelection, dropdownSearchHandler, restoredDropdownValue };
