const { ActionStyle } = require("./action-api.cjs");
const { absoluteFilePath } = require("./finder-reveal.cjs");
const { Trash } = require("./icon-values.cjs");

const maximumPaths = 8;
const maximumPathBytes = 4096;

function trashComponent(component) {
  const action = component("trashFiles");
  return (props) => action({
    ...props,
    title: props?.title ?? "Move to Trash",
    icon: props?.icon ?? Trash,
    style: ActionStyle.Destructive,
  });
}

function trashEffect(path) {
  const input = Array.isArray(path) ? path : [path];
  if (input.length === 0 || input.length > maximumPaths) {
    throw new RangeError("Trash requires between one and eight paths");
  }
  const paths = [...new Set(input.map(absoluteFilePath))];
  if (paths.includes("/") || paths.reduce((bytes, path) => bytes + Buffer.byteLength(path), 0) > maximumPathBytes) {
    throw new TypeError("Invalid Trash paths");
  }
  return { kind: "trashFiles", paths };
}

function makeTrash(emit) {
  return async function trash(path) {
    await emit(trashEffect(path));
  };
}

module.exports = { trashComponent, trashEffect, makeTrash };
