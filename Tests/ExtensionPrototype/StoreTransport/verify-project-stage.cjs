'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { receiveProject } = require('./project-stage.cjs');
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const envelope = files => Buffer.from(JSON.stringify({
  version: 1, files: files.map(([path, body]) => {
    const bytes = Buffer.from(body);
    return { path, body: bytes.toString('base64'), sha256: digest(bytes) };
  })
}));

function fixture(t) {
  const parent = fs.mkdtempSync(path.join(os.tmpdir(), 'keylane-store-stage-test-'));
  t.after(() => fs.rmSync(parent, { recursive: true, force: true }));
  return {
    parent, receive(bytes, entry, modify = x => x) {
      const transfer = '8'.repeat(32);
      return receiveProject({ transfer, bytes: bytes.length, sha256: digest(bytes) }, async request => ({
        transfer, offset: request.offset,
        body: modify(bytes.subarray(request.offset, request.offset + request.length)).toString('base64')
      }), { parent, entry });
    }
  };
}

test('inert scoped dependencies and long multichunk source materialize as fresh data only', async (t) => {
  const f = fixture(t);
  const source = 'throw new Error("must never execute");\n' + ' '.repeat(9600);
  const files = envelope([['src/index.ts', source], ['node_modules/@scope/data/index.js', 'not executed']]);
  const first = await f.receive(files, 'src/index.ts');
  const second = await f.receive(files, 'src/index.ts');
  assert.notEqual(first.directory, second.directory);
  assert.equal(fs.readFileSync(path.join(first.directory, 'src/index.ts'), 'utf8'), source);
  assert.equal(fs.readFileSync(path.join(first.directory, 'node_modules/@scope/data/index.js'), 'utf8'), 'not executed');
  assert.equal(fs.statSync(path.join(first.directory, 'src/index.ts')).mode & 0o777, 0o400);
});
test('missing or unsupported entry leaves no staging directories', async (t) => {
  const f = fixture(t);
  const files = envelope([['src/no.txt', 'inert']]);
  await assert.rejects(f.receive(files, 'src/no.txt'), /supported project entry/);
  await assert.rejects(f.receive(files, 'src/absent.ts'), /supported project entry/);
  assert.deepEqual(fs.readdirSync(f.parent), []);
});
test('invalid path and corrupted body are rejected before any file creation', async (t) => {
  const f = fixture(t);
  await assert.rejects(f.receive(envelope([['../escape.ts', 'not used']]), '../escape.ts'), /path/);
  await assert.rejects(f.receive(envelope([['src/index.ts\n', 'not used']]), 'src/index.ts\n'), /path/);
  const files = envelope([['src/index.ts', 'inert']]);
  await assert.rejects(f.receive(files, 'src/index.ts', x => Buffer.alloc(x.length)), /digest/);
  assert.deepEqual(fs.readdirSync(f.parent), []);
});
