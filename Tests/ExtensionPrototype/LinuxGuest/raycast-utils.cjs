const { existsSync } = require("node:fs");
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

  // The database path is resolved inside this VM, which has no host filesystem mount.
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
