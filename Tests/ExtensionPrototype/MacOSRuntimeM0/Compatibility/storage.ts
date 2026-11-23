// Private fixture bridge, not a claim about public asynchronous LocalStorage.
const saved = JSON.parse(__m0Request(JSON.stringify({v:1,id:1,op:"storage.set",key:"item",value:"fixture"})));
const loaded = JSON.parse(__m0Request(JSON.stringify({v:1,id:2,op:"storage.get",key:"item"})));
globalThis.__m0Result = JSON.stringify({kind:"storage",matched:saved.ok && loaded.ok && loaded.value === "fixture"});
