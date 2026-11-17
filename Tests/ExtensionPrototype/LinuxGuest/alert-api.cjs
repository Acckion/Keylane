const { AlertActionStyle } = require("./foundation-api.cjs");
const { describeImage } = require("./image-api.cjs");

function boundedText(value, limit, field, allowEmpty = false) {
  if (typeof value !== "string" || (!allowEmpty && !value.trim()) || Buffer.byteLength(value) > limit) {
    throw new TypeError(`Invalid alert ${field}`);
  }
  return value;
}

function describeAction(value, fallback) {
  if (value === undefined) return fallback;
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      (value.onAction !== undefined && typeof value.onAction !== "function")) {
    throw new TypeError("Invalid alert action");
  }
  const style = value.style ?? fallback.style;
  if (!Object.values(AlertActionStyle).includes(style)) throw new TypeError("Invalid alert action style");
  return { title: boundedText(value.title, 256, "button title"), style };
}

function makeConfirmAlert(request) {
  return async function confirmAlert(options) {
    if (!options || typeof options !== "object" || Array.isArray(options) ||
        (options.rememberUserChoice !== undefined && typeof options.rememberUserChoice !== "boolean")) {
      throw new TypeError("Invalid alert options");
    }
    const { title, message, primaryAction, dismissAction, rememberUserChoice, icon } = options;
    const image = describeImage(icon, true, true);
    const imageData = image === undefined ? undefined : Buffer.from(JSON.stringify(image));
    const payload = {
      title: boundedText(title, 256, "title"),
      message: message === undefined ? undefined : boundedText(message, 2048, "message", true),
      primaryAction: describeAction(primaryAction, { style: AlertActionStyle.Default }),
      dismissAction: describeAction(dismissAction, { style: AlertActionStyle.Cancel }),
      rememberUserChoice: rememberUserChoice ?? false,
      icon: imageData?.length <= 4096 ? imageData.toString("base64") : undefined,
    };
    const reply = await request(JSON.stringify(payload));
    if (reply !== "primary" && reply !== "dismiss") throw new Error("Invalid alert response");
    await (reply === "primary" ? primaryAction : dismissAction)?.onAction?.();
    return reply === "primary";
  };
}

module.exports = { makeConfirmAlert };
