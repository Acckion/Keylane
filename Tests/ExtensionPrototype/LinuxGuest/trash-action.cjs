const { resolvedFilePath } = require("./finder-reveal.cjs");
const { Trash } = require("./icon-values.cjs");

const maximumPaths = 8;
const maximumPathBytes = 4096;

function trashComponent(component) {
  const { ActionStyle } = require("./action-api.cjs");
  const action = component("trashFiles");
  return (props) => action({
    ...props,
    title: props?.title ?? "Move to Trash",
    icon: props?.icon ?? Trash,
    style: ActionStyle.Destructive,
  });
}

function trashPaths(input) {
  const paths = [...new Set(input.map(resolvedFilePath))];
  const unique = new Set(paths);
  if (unique.has("/")) throw new TypeError("Invalid Trash paths");
  for (const path of paths) {
    let end = path.lastIndexOf("/");
    while (end > 0) {
      if (unique.has(path.slice(0, end))) throw new TypeError("Trash paths overlap");
      end = path.lastIndexOf("/", end - 1);
    }
  }
  return paths;
}

function trashEffect(path) {
  const input = Array.isArray(path) ? path : [path];
  if (input.length === 0 || input.length > maximumPaths) {
    throw new RangeError("Trash requires between one and eight paths");
  }
  const paths = trashPaths(input);
  if (paths.reduce((bytes, path) => bytes + Buffer.byteLength(path), 0) > maximumPathBytes) {
    throw new TypeError("Invalid Trash paths");
  }
  return { kind: "trashFiles", paths };
}

function makeTrash(emit) {
  return async function trash(path) {
    const paths = trashPaths(Array.isArray(path) ? path : [path]);
    let batch = [];
    let bytes = 0;
    for (const path of paths) {
      const size = Buffer.byteLength(path);
      if (batch.length === maximumPaths || bytes + size > maximumPathBytes) {
        await emit({ kind: "trashFiles", paths: batch });
        batch = [];
        bytes = 0;
      }
      batch.push(path);
      bytes += size;
    }
    if (batch.length) await emit({ kind: "trashFiles", paths: batch });
  };
}

module.exports = { trashComponent, trashEffect, makeTrash };
