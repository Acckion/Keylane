const { createHash } = require("node:crypto");

function viewText(value) {
  const text = typeof value === "string" ? value : value?.value;
  return typeof text === "string" ? text : undefined;
}

function searchable(value) {
  return value?.normalize("NFKD").replace(/\p{Mark}/gu, "").toLowerCase() ?? "";
}

function matchScore(field, token) {
  if (field === token) return 0;
  if (field.startsWith(token)) return 1;
  if (field.includes(token)) return 2;
  let offset = 0;
  for (const character of token) {
    const index = field.indexOf(character, offset);
    if (index < 0) return Infinity;
    offset = index + character.length;
  }
  return 3;
}

function viewItemIDs(groups, { onSelectionChange, selectedItemId }) {
  const identities = new Map();
  const occurrences = new Map();
  const explicit = new Set(groups.flatMap(({ items }) => items.map(({ props }) => props.id)));
  const generate = typeof onSelectionChange === "function" || selectedItemId !== undefined;
  for (const { items } of groups) {
    for (const item of items) {
      if (typeof item.props.id === "string") {
        if (Buffer.byteLength(item.props.id) <= 256) identities.set(item, item.props.id);
        continue;
      }
      if (!generate) continue;
      const key = JSON.stringify([item.type, item.key ?? null, viewText(item.props.title)]);
      let occurrence = occurrences.get(key) ?? 0;
      let id;
      do {
        const hex = createHash("sha256").update(JSON.stringify([key, occurrence++])).digest("hex");
        id = `${hex.slice(0, 8)}-${hex.slice(8, 12)}-8${hex.slice(13, 16)}-8${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
      } while (explicit.has(id));
      occurrences.set(key, occurrence);
      identities.set(item, id);
    }
  }
  return identities;
}

function filterViewGroups(groups, { filtering, enableFiltering, onSearchTextChange }, query) {
  const enabled = filtering ?? enableFiltering ?? (typeof onSearchTextChange !== "function");
  const tokens = searchable(viewText(query)).split(/\s+/).filter(Boolean);
  if (!enabled || !tokens.length) return groups;

  const visible = groups.flatMap((group) => {
    const matches = group.items.map((item) => {
      const { title, keywords } = item.props;
      const fields = [title, ...(Array.isArray(keywords) ? keywords : [])]
        .map((value) => searchable(viewText(value)));
      const score = tokens.reduce((sum, token) =>
        sum + fields.reduce((best, field) => Math.min(best, matchScore(field, token)), Infinity), 0);
      return { item, score };
    }).filter(({ score }) => Number.isFinite(score)).sort((a, b) => a.score - b.score);
    return matches.length ? [{ group, matches }] : [];
  });
  if (filtering?.keepSectionOrder !== true) {
    visible.sort((a, b) => a.matches[0].score - b.matches[0].score);
  }
  return visible.map(({ group, matches }) => ({ ...group, items: matches.map(({ item }) => item) }));
}

module.exports = { filterViewGroups, viewItemIDs, viewText };
