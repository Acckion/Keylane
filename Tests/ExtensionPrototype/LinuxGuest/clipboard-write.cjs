const { absoluteFilePath } = require("./finder-reveal.cjs");

function contentText(value) {
  if (typeof value !== "string" || Buffer.byteLength(value) > 4096 || /[\uD800-\uDFFF]/u.test(value)) {
    throw new TypeError("Expected bounded clipboard text");
  }
  return value;
}

function clipboardEffect(kind, content, options) {
  if (typeof content === "number" && Number.isFinite(content)) content = String(content);
  let payload;
  if (typeof content === "string") {
    payload = { text: contentText(content) };
  } else if (content && typeof content === "object" && !Array.isArray(content)) {
    if ("file" in content) {
      if ("html" in content || "text" in content) throw new TypeError("Expected one clipboard content type");
      payload = { file: absoluteFilePath(content.file) };
    } else if ("html" in content) {
      payload = { html: contentText(content.html) };
      if (content.text !== undefined) payload.text = contentText(content.text);
    } else {
      payload = { text: contentText(content.text) };
    }
  } else {
    throw new TypeError("Expected text, a number, HTML or a local file");
  }

  const concealed = kind === "copy" && (options?.concealed ?? options?.transient) === true;
  const keepOpen = kind === "paste" && options?.closeMainWindow === false;
  if (payload.text !== undefined && payload.html === undefined && !concealed && !keepOpen &&
      Buffer.byteLength(payload.text) <= 1024) return { kind, text: payload.text };
  return { kind, clipboardContent: payload, ...(concealed && { concealed }), ...(keepOpen && { keepOpen }) };
}

function clipboardWritePayload(content, options) {
  const effect = clipboardEffect("copy", content, options);
  const payload = JSON.stringify({
    content: effect.clipboardContent ?? { text: effect.text },
    concealed: effect.concealed === true,
  });
  // The payload travels as a JSON string inside the request frame.
  if (Buffer.byteLength(JSON.stringify(payload)) > 12_288) throw new RangeError("Clipboard content is too large");
  return payload;
}

module.exports = { clipboardEffect, clipboardWritePayload };
