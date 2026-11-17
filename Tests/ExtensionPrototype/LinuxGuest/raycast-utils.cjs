const { existsSync } = require("node:fs");
const { copyFile, mkdtemp, rm, stat } = require("node:fs/promises");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { environment } = require("./environment.cjs");
const { utilitiesHooksFor } = require("./utilities-hooks.cjs");
const cacheUtilities = require("./utilities-cache.cjs");
const deeplinkUtilities = require("./utilities-deeplinks.cjs");
const { utilitiesRuntimeHooksFor } = require("./utilities-runtime-hooks.cjs");
const { utilitiesDataHooksFor } = require("./utilities-data-hooks.cjs");
const { getAvatarIcon, getProgressIcon, makeShowFailureToast } = require("./utilities-visual-feedback.cjs");

const FormValidation = Object.freeze({ Required: "required" });

async function executeSQL(databasePath, query) {
  if (!existsSync(databasePath)) {
    throw new Error("The database does not exist");
  }

  try {
    return readDatabase(databasePath, query);
  } catch (error) {
    // SQLite includes extended flags in the high bits of an error code.
    const code = error.errcode & 0xff;
    if (code !== 5 && code !== 14) throw error; // SQLITE_BUSY and SQLITE_CANTOPEN
    const source = await stat(databasePath);
    if (!source.isFile() || source.size > 64 * 1024 * 1024) throw error;
    const parent = process.env.KEYLANE_PHASE ? environment.supportPath : tmpdir();
    const directory = await mkdtemp(join(parent, "sql-snapshot-"));
    try {
      const snapshot = join(directory, "database.sqlite");
      await copyFile(databasePath, snapshot);
      // Match the utility's best-effort recovery from the main file alone.
      // Recent writes in a separate WAL may be absent from this snapshot.
      return readDatabase(snapshot, query);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  }
}

function readDatabase(databasePath, query) {
  // Both the original and the recovery snapshot are scoped to the guest.
  const { DatabaseSync } = require("node:sqlite");
  const database = new DatabaseSync(databasePath, { readOnly: true });
  try {
    database.exec("PRAGMA query_only = ON");
    const statement = database.prepare(query);
    // VACUUM INTO can create a file even when the connection opens read-only.
    if (statement.columns().length === 0) {
      throw new Error("The SQL query must be read-only and return rows");
    }
    return statement.all();
  } finally {
    database.close();
  }
}

const shared = { FormValidation, executeSQL, getAvatarIcon, getProgressIcon, ...deeplinkUtilities };

function utilitiesFor(apiProvider) {
  const hooks = utilitiesHooksFor(apiProvider, FormValidation);
  return {
    ...shared, ...hooks, ...cacheUtilities, ...utilitiesDataHooksFor(hooks.usePromise, executeSQL),
    ...utilitiesRuntimeHooksFor(apiProvider, hooks.usePromise),
    showFailureToast: makeShowFailureToast(apiProvider),
  };
}

module.exports = { ...shared, utilitiesFor };
