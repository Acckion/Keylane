'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const test = require('node:test');
const { artifactFrames, decodeLaunch } = require('./store-stage.cjs');
test('artifact data is exported as ordered bounded frames with one identity', () => {
  const bytes = Buffer.alloc(2 * 8192 + 3, 9);
  const parts = [...artifactFrames(bytes)];
  assert.equal(parts.length, 5);
  const sha256 = crypto.createHash('sha256').update(bytes).digest('hex');
  assert.deepEqual(parts[0], { kind: 'artifact-start', bytes: bytes.length, sha256 });
  assert.deepEqual(parts.slice(1, 4).map(f => f.offset), [0, 8192, 16384]);
  assert(parts.every(f => Buffer.byteLength(JSON.stringify(f)) < 16384));
  assert.deepEqual(Buffer.concat(parts.slice(1, 4).map(f => Buffer.from(f.body, 'base64'))), bytes);
  assert.deepEqual(parts[4], { kind: 'artifact-done', sha256 });
});
test('zero, undefined, and over-budget artifact bytes are refused', () => {
  for (const bad of [undefined, Buffer.alloc(0), Buffer.alloc(4 * 1024 * 1024 + 1)])
    assert.throws(() => artifactFrames(bad), /artifact size/);
});

test('generic bounded launch args preserve typed strings and separately flag preference load', () => {
  const source = { version: 1, arguments: { message: 'hello', optional: 'line\nbreak' }, loadPreferences: true };
  assert.deepEqual(decodeLaunch(Buffer.from(JSON.stringify(source))), source);
  for (const bad of [
    '{"version":1,"arguments":{"__proto__":"bad"},"loadPreferences":false}',
    '{"version":1,"arguments":{"actual":2},"loadPreferences":false}',
    '{"version":1,"arguments":{},"loadPreferences":false,"preferences":{}}',
    '{"version":1,"arguments":{},"loadPreferences":"true"}'
  ]) assert.throws(() => decodeLaunch(Buffer.from(bad)), /launch/);
});
