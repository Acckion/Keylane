'use strict';
// Sealed test adapter: receives package bytes, returns metadata, NEVER executes them.
const fs = require('node:fs');
const { receivePackage } = require('./receive-package.cjs');
let pending = Buffer.alloc(0);
async function line() {
 for (;;) {
  const index=pending.indexOf(10);
  if(index>=0){if(index>16384)throw new Error('frame');const result=pending.subarray(0,index);pending=pending.subarray(index+1);return JSON.parse(result.toString('utf8'));}
  if(pending.length>16384)throw new Error('frame');
  const chunk=Buffer.alloc(4096);
  const count=await new Promise((resolve,reject)=>fs.read(3,chunk,0,chunk.length,null,(error,n)=>error?reject(error):resolve(n)));
  if(!count)throw new Error('EOF');pending=Buffer.concat([pending,chunk.subarray(0,count)]);
 }
}
(async()=>{
 const descriptor=await line();
 const result=await receivePackage(descriptor,async request=>{
  fs.writeSync(3,JSON.stringify(request)+'\n');return await line();
 });
 if(process.argv[2]==='receive-source' || process.argv[2]==='receive-artifact'){
  const source=process.argv[2]==='receive-source';
  const key=source?'src/fixture.ts':'bundle.cjs';
  if(result.size!==1 || !result.has(key) || result.get(key).length>4096)throw new Error('fixed fixture recipe');
  fs.writeFileSync(source?'/handoff/source.ts':'/handoff/bundle.cjs',result.get(key),{flag:'wx',mode:0o400});
  fs.writeSync(3,'{"received":true}\n'); process.exit(0);
 }
 fs.writeSync(3,JSON.stringify({done:true,files:result.size,bytes:[...result.values()].reduce((n,b)=>n+b.length,0)})+'\n');
 process.exit(0);
})().catch(error=>{console.error('fixture receiver:',error.message);fs.writeSync(3,'{"rejected":true}\n');process.exit(1);});
