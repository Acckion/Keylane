const { fileURLToPath } = require("node:url");
const { extname } = require("node:path");

function pathType(value) {
  const path = value instanceof URL ? fileURLToPath(value) :
    Buffer.isBuffer(value) ? new TextDecoder("utf-8", { fatal: true }).decode(value) : value;
  if (typeof path !== "string" || !path || Buffer.byteLength(path) > 4096 || path.includes("\0") ||
      /^[a-z][a-z0-9+.-]*:\/\//i.test(path)) {
    throw new TypeError("Expected a file path or file URL");
  }
  if (path.endsWith("/")) return { directory: true };
  const extension = extname(path).slice(1).toLowerCase();
  if (!/^[a-z0-9][a-z0-9_+-]{0,31}$/.test(extension)) {
    throw new TypeError("Expected a filename extension or a directory path ending with a slash");
  }
  return { extension };
}

function makeApplicationQueries(request) {
  const query = async (operation, type = {}) =>
    JSON.parse(await request("applications.query", JSON.stringify({ operation, ...type })));

  return {
    async getApplications(path) {
      return query("list", path === undefined ? undefined : pathType(path));
    },
    async getDefaultApplication(path) {
      return query("default", pathType(path));
    },
    async getFrontmostApplication() {
      return query("frontmost");
    },
  };
}

module.exports = { makeApplicationQueries };
