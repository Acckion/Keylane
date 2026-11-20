"use strict";
const fs=require('node:fs'),crypto=require('node:crypto');
(async()=>{
 if(process.argv[2]==='export'){
  const stat=fs.lstatSync('/work/bundle.cjs');
  if(!stat.isFile() || stat.size>4096)throw Error('artifact bound');
  const data=fs.readFileSync('/work/bundle.cjs');
  fs.writeSync(3,JSON.stringify({artifact:data.toString('base64'),sha256:crypto.createHash('sha256').update(data).digest('hex')})+'\n');
 }else if(process.argv[2]==='execute'){
  const command=require('/handoff/bundle.cjs');
  if(fs.existsSync('/real-api')){
   const api=require('/raycast-api.cjs'); api.connect();
   await api.runNoViewCommand(()=>command.default());
   await require('node:assert/strict').rejects(api.request('files.trash','[]'),/Capability unavailable/);
   const receipt=await api.request('echo','real-api-host-receipt');
   fs.writeSync(3,JSON.stringify({executed:true,realAPI:true,receipt})+'\n');
   process.exit(0);
  }
  await command.default();
  fs.writeSync(3,JSON.stringify({executed:true,stub:true,result:global.fixtureResult})+'\n');
 }else throw Error('stage');
 process.exit(0);
})().catch(e=>{console.error(e);process.exit(1)});
