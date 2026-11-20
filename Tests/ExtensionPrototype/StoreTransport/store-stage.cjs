'use strict';

// Sealed guest entry. Only the guest init selects the action and paths. This
// module is not a host entry point or shell for package-controlled arguments.
const crypto = require('node:crypto');
const fs = require('node:fs');
const { receiveProject } = require('./project-stage.cjs');
const { receivePackage } = require('./receive-package.cjs');
const MAX_ARTIFACT = 4 * 1024 * 1024;
const MAX_LINE = 16 * 1024;

function transport(fd) {
  // Read exactly to the frame delimiter. Separate guest workers share the same
  // socket and must never read ahead into a future worker's messages.
  return {
    read() {
      const result = Buffer.alloc(MAX_LINE);
      const byte = Buffer.alloc(1);
      for (let index = 0; index <= result.length; index++) {
        if (fs.readSync(fd, byte, 0, 1, null) !== 1) throw new Error('guest input closed');
        if (byte[0] === 10) return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(result.subarray(0, index)));
        if (index === result.length) throw new Error('guest input frame too large');
        result[index] = byte[0];
      }
      throw new Error('guest input invalid');
    },
    write(frame) {
      const bytes = Buffer.from(JSON.stringify(frame) + '\n');
      if (bytes.length > MAX_LINE + 1) throw new Error('guest output frame too large');
      for (let offset = 0; offset < bytes.length;) {
        const count = fs.writeSync(fd, bytes, offset);
        if (count <= 0) throw new Error('guest output closed');
        offset += count;
      }
    }
  };
}

function artifactFrames(artifact) {
  if (!Buffer.isBuffer(artifact) || !artifact.length || artifact.length > MAX_ARTIFACT) throw new Error('artifact size');
  const sha256 = crypto.createHash('sha256').update(artifact).digest('hex');
  return (function* () {
    yield { kind: 'artifact-start', bytes: artifact.length, sha256 };
    for (let i = 0; i < artifact.length; i += 8192)
      yield { kind: 'artifact-chunk', offset: i, body: artifact.subarray(i, i + 8192).toString('base64') };
    yield { kind: 'artifact-done', sha256 };
  })();
}

function decodeLaunch(bytes) {
  if (!Buffer.isBuffer(bytes) || !bytes.length || bytes.length > 4096) throw new Error('launch size');
  const launch = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  if (!launch || typeof launch !== 'object' || Array.isArray(launch) || launch.version !== 1 ||
      Object.keys(launch).sort().join(' ') !== 'arguments loadPreferences version' ||
      typeof launch.loadPreferences !== 'boolean' || !launch.arguments ||
      typeof launch.arguments !== 'object' || Array.isArray(launch.arguments)) throw new Error('launch envelope');
  const items = Object.entries(launch.arguments);
  if (items.length > 16 || items.some(([key, value]) => !key.length || key.length > 64 ||
      /[^A-Za-z0-9_-]/.test(key) || ['__proto__', 'constructor', 'prototype'].includes(key) ||
      typeof value !== 'string' || Buffer.byteLength(value) > 1024)) throw new Error('launch arguments');
  // Leave a normal mutable arguments object: some Raycast commands fill
  // optional defaults in props.arguments. No credentials or other data.
  return launch;
}

async function stage(action, channel, entry) {
  const pull = request => { channel.write(request); return channel.read(); };
  if (action === 'receive-source') {
    const descriptor = channel.read();
    const result = await receiveProject(descriptor, pull, { parent: '/staging/', entry });
    fs.renameSync(result.directory, '/staging/project');
    channel.write({ kind: 'received' });
  } else if (action === 'receive-artifact') {
    const descriptor = channel.read();
    // The artifact plus bounded launch data fit the 6 MiB wire ceiling.
    if (descriptor?.bytes > 6 * 1024 * 1024) throw new Error('artifact wire size');
    const decoded = await receivePackage(descriptor, pull);
    const artifact = decoded.get('bundle.cjs');
    const launch = decoded.get('launch.json');
    if (decoded.size !== 2 || !artifact?.length || artifact.length > MAX_ARTIFACT) throw new Error('artifact envelope');
    decodeLaunch(launch);
    fs.writeFileSync('/staging/bundle.cjs', artifact, { flag: 'wx', mode: 0o400 });
    fs.writeFileSync('/staging/launch.json', launch, { flag: 'wx', mode: 0o400 });
    channel.write({ kind: 'received' });
  } else if (action === 'export-artifact') {
    const file = fs.openSync('/work/bundle.cjs', fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    try {
      const { size, nlink } = fs.fstatSync(file);
      if (!fs.fstatSync(file).isFile() || nlink !== 1 || size < 1 || size > MAX_ARTIFACT) throw new Error('artifact file');
      for (const frame of artifactFrames(fs.readFileSync(file))) channel.write(frame);
    } finally { fs.closeSync(file); }
  } else if (action === 'run-artifact') {
    const launch = decodeLaunch(fs.readFileSync('/staging/launch.json'));
    const api = require('/raycast-api.cjs');
    api.connect();
    if (launch.loadPreferences) await api.loadPreferences();
    const command = require('/staging/bundle.cjs');
    if (typeof command.default !== 'function') throw new Error('unsupported entry');
    await api.runNoViewCommand(() => command.default({ arguments: launch.arguments }));
    channel.write({ kind: 'command-done' });
  } else {
    throw new Error('unexpected guest action');
  }
}

if (require.main === module) {
  stage(process.argv[2], transport(3), process.argv[3]).then(
    () => { process.exitCode = 0; },
    () => { process.exitCode = 1; }
  );
}
module.exports = { artifactFrames, decodeLaunch };
