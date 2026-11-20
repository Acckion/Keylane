'use strict';
// Data-only boundary for a future sealed guest. Never extracts files or loads code.
const { createHash } = require('node:crypto');
const MAX_BYTES = 32 * 1024 * 1024;
const MAX_WIRE = 46 * 1024 * 1024;
function decodePackage(bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length > MAX_WIRE) throw new Error('wire limit');
  const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  const envelope = JSON.parse(text);
  if (envelope.version !== 1 || !Array.isArray(envelope.files) ||
      envelope.files.length === 0 || envelope.files.length > 4096) throw new Error('envelope');
  let total = 0;
  const result = new Map();
  const aliases = new Set();
  for (const entry of envelope.files) {
    if (!entry || typeof entry.path !== 'string' || typeof entry.body !== 'string' ||
        typeof entry.sha256 !== 'string') throw new Error('entry');
    const path = entry.path;
    if (Buffer.byteLength(path) > 1024 || /[^A-Za-z0-9_@.+/-]/.test(path) ||
        path.split('/').some(p => !p || p === '.' || p === '..' || p.startsWith('-')))
      throw new Error('path');
    const alias = path.toLowerCase();
    if (aliases.has(alias)) throw new Error('duplicate');
    aliases.add(alias);
    if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(entry.body))
      throw new Error('base64');
    const body = Buffer.from(entry.body, 'base64');
    total += body.length;
    if (total > MAX_BYTES) throw new Error('data limit');
    if (body.toString('base64') !== entry.body ||
        createHash('sha256').update(body).digest('hex') !== entry.sha256) throw new Error('digest');
    result.set(path, body);
  }
  // Reject file/directory ambiguity, regardless of case or entry ordering.
  for (const path of aliases) {
    const parts = path.split('/');
    for (let i = 1; i < parts.length; i++)
      if (aliases.has(parts.slice(0, i).join('/'))) throw new Error('prefix collision');
  }
  return result;
}
module.exports = { decodePackage, MAX_BYTES, MAX_WIRE };
