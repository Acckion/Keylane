'use strict';
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { decodePackage, MAX_WIRE } = require('./package-data.cjs');
const file = (path, text = 'controlled fixture') => {
 const body = Buffer.from(text); return { path, body: body.toString('base64'), sha256: createHash('sha256').update(body).digest('hex') };
};
const wire = files => Buffer.from(JSON.stringify({version: 1, files}));
assert.equal(decodePackage(wire([file('src/index.ts')])).get('src/index.ts').toString(), 'controlled fixture');
// Contents are data: a would-be script is never evaluated by the decoder.
assert.equal(decodePackage(wire([file('index.js', 'throw new Error("must not run")')])).size, 1);
for (const path of ['/abs', '../escape', 'a/../b', 'a//b', 'a\\b', 'a\0b', './a', 'a/', '-flag', 'a/é'])
 assert.throws(() => decodePackage(wire([file(path)])));
for (const files of [[file('a'),file('a')], [file('A'),file('a')], [file('a'),file('a/b')], [file('A/b'),file('a')]])
 assert.throws(() => decodePackage(wire(files)));
assert.throws(() => decodePackage(wire([{...file('a'),sha256:'0'.repeat(64)}])));
assert.throws(() => decodePackage(wire([{...file('a'),body:'not base64'}])));
assert.throws(() => decodePackage(Buffer.from([255])));
assert.throws(() => decodePackage(Buffer.alloc(MAX_WIRE + 1)));
assert.throws(() => decodePackage(wire(Array.from({length:4097}, (_,i)=>file('f'+i)))));
assert.throws(() => decodePackage(wire([file('large', 'x'.repeat(32*1024*1024+1))])));
assert.throws(() => decodePackage(wire([])));
assert.throws(() => decodePackage(Buffer.from('{"version":2,"files":[]}')));
console.log('package-data: valid data and rejection/non-execution checks passed');
