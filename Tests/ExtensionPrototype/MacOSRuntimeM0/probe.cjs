'use strict';
// Runs without --permission and without an API shim: observed denials must come
// from the OS boundary, not a JavaScript policy pretending to be a sandbox.
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');
const os = require('node:os');
const cp = require('node:child_process');
const report = { version: process.version, pid: process.pid, cases: {} };
const attempt = (name, action) => {
  try { action(); report.cases[name] = { allowed: true }; }
  catch (e) { report.cases[name] = { allowed: false, code: e.code ?? e.name }; }
};
const config = CONFIG_PLACEHOLDER;
(async () => {
  if (config.mode === 'hang' || config.mode === 'detached') {
    const child = cp.spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { stdio: 'ignore', detached: config.mode === 'detached' });
    console.log(JSON.stringify({ ready: true, pid: process.pid, descendant: child.pid }));
    setInterval(() => {}, 1000);
    return;
  }
  if (config.mode === 'abnormal') process.exit(42);
  attempt('hostRead', () => { if (fs.readFileSync(config.secret, 'utf8') !== config.marker) throw Error('wrong fixture'); });
  attempt('hostWrite', () => fs.writeFileSync(config.output, 'synthetic-only'));
  attempt('symlinkRead', () => fs.readFileSync(config.link));
  attempt('spawnSystem', () => cp.execFileSync('/usr/bin/true', [], { stdio: 'ignore', timeout: 2000 }));
  attempt('spawnNode', () => cp.execFileSync(process.execPath, ['-e', 'process.exit(0)'], { stdio: 'ignore', timeout: 2000 }));
  try {
    const child = cp.execFileSync(process.execPath, ['-e',
      `try { require('node:fs').readFileSync(${JSON.stringify(config.secret)}); console.log('allowed'); } catch (e) { console.log(e.code); }`],
      { encoding: 'utf8', timeout: 2000 });
    report.cases.childHostRead = { allowed: child.trim() === 'allowed', code: child.trim() };
  } catch (e) { report.cases.childHostRead = { allowed: false, code: e.code ?? e.name }; }
  // Write in one invocation, read in another: checks the shared-container claim.
  const container = process.env.KEYLANE_M0_CONTAINER ?? os.homedir();
  const target = path.join(container, config.containerName);
  attempt('containerWrite', () => fs.writeFileSync(target, config.marker));
  attempt('crossInvocationRead', () => {
    if (config.mode !== 'read') throw Error('not reader');
    if (fs.readFileSync(path.join(container, config.previousName), 'utf8') !== config.marker) throw Error('wrong fixture');
  });
  report.cases.network = await new Promise(resolve => {
    const socket = net.connect({ host: '127.0.0.1', port: config.port });
    const finish = value => { socket.destroy(); resolve(value); };
    socket.setTimeout(1500, () => finish({ allowed: false, code: 'TIMEOUT' }));
    socket.on('connect', () => finish({ allowed: true }));
    socket.on('error', e => finish({ allowed: false, code: e.code }));
  });
  attempt('jit', () => {
    const f = new Function('n', 'let r=0;for(let i=0;i<n;i++)r+=i;return r');
    for (let i = 0; i < 5000; i++) if (f(100) !== 4950) throw Error('bad jit result');
  });
  // Remove only this fixture's random marker files, never the container itself.
  if (config.mode === 'read') for (const name of [config.containerName, config.previousName]) {
    try { fs.unlinkSync(path.join(container, name)); } catch {}
  }
  if (config.slotTarget) attempt('foreignSlotRead', () => fs.readFileSync(config.slotTarget));
  if (config.mode === 'slotWrite') report.fixturePath = target;
  if (config.probeFD !== undefined) attempt('inheritedDescriptor', () => {
    if (fs.readFileSync(config.probeFD, 'utf8') !== config.marker) throw Error('wrong fixture');
  });
  if (config.mode === 'slotClean') attempt('markerCleanup', () => fs.unlinkSync(target));
  report.rssBytes = process.memoryUsage().rss;
  console.log(JSON.stringify(report));
})().catch(() => process.exit(71));
