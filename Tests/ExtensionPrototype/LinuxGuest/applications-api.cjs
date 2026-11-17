const { lstat, realpath, stat } = require("node:fs/promises");
const { fileURLToPath } = require("node:url");
const { basename, extname } = require("node:path");

const namedFiles = new Set(["authors", "copying", "license", "makefile", "readme"]);

async function pathType(value, followSymlinks, selectedFileIndex) {
  const input = value instanceof URL ? value.href :
    Buffer.isBuffer(value) ? new TextDecoder("utf-8", { fatal: true }).decode(value) : value;
  if (typeof input !== "string" || !input || Buffer.byteLength(input) > 4096 || /[\x00-\x1f\x7f]/.test(input)) {
    throw new TypeError("Expected a file path or URL");
  }

  const scheme = /^[a-z][a-z0-9+.-]*:/i.exec(input)?.[0].slice(0, -1).toLowerCase();
  let path = input;
  if (scheme) {
    if (scheme.length > 32) throw new TypeError("Invalid URL scheme");
    const url = new URL(input);
    if (scheme !== "file") return { scheme };
    path = fileURLToPath(url);
  }
  if (/[\x00-\x1f\x7f]/.test(path)) throw new TypeError("Expected a file path or URL");
  const selectedFile = selectedFileIndex(path);
  if (selectedFile !== -1) return { selectedFile };
  // Only the guest filesystem is consulted. Dotted directories must be
  // recognized before applying the filename-extension fallback.
  const info = await (followSymlinks ? stat(path) : lstat(path)).catch(() => undefined);
  if (info?.isSymbolicLink()) return { symlink: true };
  if (info?.isDirectory() || (!info && path.endsWith("/"))) return { directory: true };
  // The default-app query follows the link while the handler list uses its own type.
  const file = followSymlinks && info ? await realpath(path).catch(() => path) : path;
  const extension = extname(file).slice(1).toLowerCase();
  if (!extension) {
    const name = basename(file).toLowerCase();
    return { extensionless: namedFiles.has(name) ? name : "generic" };
  }
  if (!/^[a-z0-9][a-z0-9_+-]{0,31}$/.test(extension)) {
    throw new TypeError("Invalid filename extension");
  }
  return { extension };
}

function makeApplicationQueries(request, selectedFileIndex = () => -1) {
  const query = async (operation, type = {}) => {
    const capability = operation === "list" && type.offset > 0 ? "applications.listPage" : "applications.query";
    return JSON.parse(await request(capability, JSON.stringify({ operation, ...type })));
  };

  // Keep each result's continuation together when extensions issue parallel reads.
  let listing = Promise.resolve();
  async function list(type) {
    const applications = [];
    let offset = 0;
    for (;;) {
      const page = await query("list", { ...type, offset });
      if (!Array.isArray(page?.items)) throw new Error("Invalid application list page");
      applications.push(...page.items);
      if (page.nextOffset === undefined) return applications;
      if (page.items.length === 0 || page.nextOffset !== applications.length) {
        throw new Error("Invalid application list continuation");
      }
      offset = page.nextOffset;
    }
  }

  return {
    async getApplications(path) {
      const type = path === undefined ? undefined : await pathType(path, false, selectedFileIndex);
      const result = listing.then(() => list(type));
      listing = result.catch(() => {});
      return result;
    },
    async getDefaultApplication(path) {
      return query("default", await pathType(path, true, selectedFileIndex));
    },
    async getFrontmostApplication() {
      const application = await query("frontmost");
      if (typeof application?.name !== "string" || !application.name ||
          typeof application.path !== "string" || !application.path.startsWith("/") ||
          (application.bundleId !== undefined && typeof application.bundleId !== "string") ||
          (application.localizedName !== undefined && typeof application.localizedName !== "string")) {
        throw new Error("No valid frontmost application was found");
      }
      return application;
    },
  };
}

module.exports = { makeApplicationQueries };
