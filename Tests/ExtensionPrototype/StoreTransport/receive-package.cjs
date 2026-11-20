'use strict';
const { createHash } = require('node:crypto');
const { decodePackage, MAX_WIRE } = require('./package-data.cjs');
// Trusted guest adapter. request must be a single host-owned, authenticated
// session capability, not an extension-supplied function or network fetch.
async function receivePackage(descriptor, request, signal) {
  if (!descriptor || !Number.isSafeInteger(descriptor.bytes) || descriptor.bytes < 1 ||
      descriptor.bytes > MAX_WIRE || !/^[a-f0-9]{64}$/.test(descriptor.sha256) ||
      !/^[a-f0-9]{32}$/.test(descriptor.transfer)) throw new Error('descriptor');
  if (typeof request !== 'function') throw new Error('transport');
  let cancelled = false;
  let rejectStop;
  const stopped = new Promise((_, reject) => { rejectStop = reject; });
  const stop = () => { cancelled = true; rejectStop(new Error('cancelled or deadline')); };
  const timer = setTimeout(stop, 15000); // Absolute, never renewed by chunk progress.
  signal?.addEventListener('abort', stop, { once: true });
  const bytes = Buffer.alloc(descriptor.bytes);
  try {
    if (signal?.aborted) throw new Error('cancelled');
    for (let offset = 0; offset < bytes.length; offset += 8192) {
      if (cancelled || signal?.aborted) throw new Error('cancelled');
      const length = Math.min(8192, bytes.length - offset);
      const reply = await Promise.race([
        Promise.resolve().then(() => request({ transfer: descriptor.transfer, offset, length })), stopped
      ]);
      if (cancelled || signal?.aborted) throw new Error('cancelled');
      if (!reply || reply.transfer !== descriptor.transfer || reply.offset !== offset ||
          typeof reply.body !== 'string' || reply.body.length > 10924) throw new Error('chunk');
      const chunk = Buffer.from(reply.body, 'base64');
      if (chunk.length !== length || chunk.toString('base64') !== reply.body) throw new Error('chunk bytes');
      chunk.copy(bytes, offset);
    }
    if (createHash('sha256').update(bytes).digest('hex') !== descriptor.sha256) throw new Error('transfer digest');
    return decodePackage(bytes);
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', stop);
    bytes.fill(0);
  }
}
module.exports = { receivePackage };
