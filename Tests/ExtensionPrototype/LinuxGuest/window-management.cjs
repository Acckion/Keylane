const maximumWindowCount = 24;
const maximumReplyBytes = 6000;

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function boundedString(value, maximumBytes) {
  return typeof value === "string" && value.length > 0 && Buffer.byteLength(value) <= maximumBytes;
}

function readWindow(value) {
  if (!isObject(value) || !boundedString(value.id, 128) || !boundedString(value.desktopId, 128) ||
      [value.active, value.positionable, value.resizable, value.fullScreenSettable].some((flag) => typeof flag !== "boolean")) {
    throw new Error("Invalid window metadata");
  }

  const { id, desktopId, active, positionable, resizable, fullScreenSettable } = value;
  const window = { id, desktopId, active, positionable, resizable, fullScreenSettable };
  if (value.bounds === "fullscreen") {
    window.bounds = value.bounds;
  } else {
    const { position, size } = value.bounds ?? {};
    if (!isObject(position) || !isObject(size) || ![position.x, position.y, size.width, size.height].every(Number.isFinite) ||
        size.width <= 0 || size.height <= 0) {
      throw new Error("Invalid window bounds");
    }
    window.bounds = { position: { x: position.x, y: position.y }, size: { width: size.width, height: size.height } };
  }

  if (value.application !== undefined) {
    const { name, path, bundleId, localizedName } = value.application ?? {};
    if (!boundedString(name, 128) || !boundedString(path, 512) || !path.startsWith("/") ||
        (bundleId !== undefined && !boundedString(bundleId, 128)) ||
        (localizedName !== undefined && !boundedString(localizedName, 128))) {
      throw new Error("Invalid window application metadata");
    }
    window.application = { name, path, ...(bundleId !== undefined && { bundleId }),
      ...(localizedName !== undefined && { localizedName }) };
  }
  return window;
}

function makeWindowManagement(request, isAllowed) {
  async function read(operation) {
    if (!isAllowed()) throw new Error("Window Management requires a selected view action with window access");
    const response = await request("window.read", operation);
    if (typeof response !== "string" || Buffer.byteLength(response) > maximumReplyBytes) {
      throw new Error("Invalid window response");
    }
    return JSON.parse(response);
  }

  return Object.freeze({
    async getActiveWindow() {
      const value = await read("active");
      if (value === null) throw new Error("No active window is available");
      return readWindow(value);
    },
    async getWindowsOnActiveDesktop() {
      const windows = await read("desktop");
      if (!Array.isArray(windows) || windows.length > maximumWindowCount) throw new Error("Invalid window list");
      return windows.map(readWindow);
    },
  });
}

module.exports = { makeWindowManagement };
