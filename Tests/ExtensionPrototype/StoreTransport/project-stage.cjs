'use strict';

// Receive a generic project as inert bytes. This module never imports the
// materialized tree, invokes a compiler, or reads paths outside the guest-only
// staging parent. The parent and entry come from the sealed guest supervisor,
// never from a package manifest, argv adapter or extension script.
const fs = require('node:fs');
const path = require('node:path');
const { receivePackage } = require('./receive-package.cjs');

const ENTRY = /(?:^|\/)[A-Za-z0-9_@.+-]+\.(?:ts|tsx|js|jsx|mjs|cjs)$/;

async function receiveProject(descriptor, exchange, { parent, entry }) {
  // receivePackage validates bounds, transfer identity, digest, all paths,
  // file/directory collisions and bytes before returning any project content.
  const files = await receivePackage(descriptor, exchange);
  if (!files.has(entry) || !ENTRY.test(entry)) throw new Error('missing supported project entry');
  const directory = fs.mkdtempSync(path.join(parent, 'store-project-'));
  try {
    for (const [relative, bytes] of files) {
      const destination = path.join(directory, relative);
      fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
      fs.writeFileSync(destination, bytes, { flag: 'wx', mode: 0o400 });
    }
    return { directory, entry };
  } catch (error) {
    fs.rmSync(directory, { recursive: true, force: true });
    throw error;
  }
}

module.exports = { receiveProject };
