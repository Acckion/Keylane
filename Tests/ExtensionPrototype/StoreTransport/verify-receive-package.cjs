'use strict';
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { receivePackage } = require('./receive-package.cjs');
const hash = b => createHash('sha256').update(b).digest('hex');
const content = Buffer.from('controlled fixture; not executable\n'.repeat(1200));
const bytes = Buffer.from(JSON.stringify({ version: 1, files: [{path:'src/fixture.txt',body:content.toString('base64'),sha256:hash(content)}] }));
const descriptor = { transfer:'a'.repeat(32), bytes:bytes.length, sha256:hash(bytes) };
const reply = r => ({transfer:r.transfer,offset:r.offset,body:bytes.subarray(r.offset,r.offset+r.length).toString('base64')});
(async () => {
 let calls=0;
 const result=await receivePackage(descriptor, async r=>{calls++;return reply(r);});
 assert.deepEqual(result.get('src/fixture.txt'),content); assert.ok(calls>1);
 for (const mutate of [r=>({...r,offset:r.offset+1}),r=>({...r,transfer:'b'.repeat(32)}),r=>({...r,body:''}),r=>({...r,body:r.body+'!'}),r=>({...r,body:'x'.repeat(10925)})])
  await assert.rejects(receivePackage(descriptor,async r=>mutate(reply(r))));
 await assert.rejects(receivePackage({...descriptor,sha256:'0'.repeat(64)},async r=>reply(r)));
 let touched=false; await assert.rejects(receivePackage({...descriptor,bytes:Infinity},async()=>{touched=true;}));assert.equal(touched,false);
 const abort=new AbortController(); let n=0;
 await assert.rejects(receivePackage(descriptor,async r=>{n++;abort.abort();return reply(r);},abort.signal));assert.equal(n,1);
 const waiting=new AbortController();
 const pending=receivePackage(descriptor,()=>new Promise(()=>{}),waiting.signal);
 setTimeout(()=>waiting.abort(),10);await assert.rejects(pending);
 console.log('receive-package: multichunk, replay/mismatch/size/digest rejection and cancellation passed');
})().catch(e=>{console.error(e);process.exitCode=1;});
