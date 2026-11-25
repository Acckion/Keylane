#!/usr/bin/env python3
"""Compile first-party TS/TSX controls, contrast Node and the restricted M0 candidate."""
import argparse
import base64
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import platform
import subprocess
import sys
import tarfile
import urllib.request

ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('broker',ROOT/'scripts/verify-macos-broker-m0.py')
broker=importlib.util.module_from_spec(spec); spec.loader.exec_module(broker)
m0,slots=broker.m0,broker.slots
FIXTURE=broker.FIXTURE/'Compatibility'
CASES={'compiledNoView','compiledReactData','compiledStorage','nodeFSPositive','nodeFSUnavailable',
       'nodeBufferPositive','nodeBufferUnavailable','nodeTimerPositive','nodeTimerUnavailable','fixturesExited'}


def verdict(cases):
    if not CASES.issubset(cases) or any(type(cases[name]) is not bool for name in CASES):
        raise RuntimeError('Missing/invalid compatibility observation')
    failures=sorted(name for name in CASES if not cases[name])
    return ('blocked',failures) if failures else ('incomplete',[])


def package(package, destination):
    # Official registry URLs and exact archive digest; no npm scripts/plugins/config.
    with urllib.request.urlopen(package['url'],timeout=30) as response:
        data=response.read(16*1024*1024+1)
    if len(data)>16*1024*1024: raise RuntimeError('Package too large')
    digest='sha512-'+base64.b64encode(hashlib.sha512(data).digest()).decode()
    if digest!=package['integrity']: raise RuntimeError('Package integrity mismatch')
    with tarfile.open(fileobj=io.BytesIO(data),mode='r:gz') as tar:
        members=tar.getmembers()
        if any((not item.isfile() and not item.isdir()) or Path(item.name).is_absolute() or '..' in Path(item.name).parts or Path(item.name).parts[0]!='package' for item in members):
            raise RuntimeError('Unsafe package entry')
        if sum(item.size for item in members)>32*1024*1024: raise RuntimeError('Expanded package limit')
        tar.extractall(destination,filter='data')
    return hashlib.sha256(data).hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report',type=Path,required=True)
    parser.add_argument('--archive',type=Path)
    args=parser.parse_args()
    if sys.platform!='darwin' or platform.machine()!='arm64': raise SystemExit('Requires arm64 macOS')
    if args.report.exists(): raise SystemExit('Refusing report overwrite')
    identity=m0.resolve_identity()
    report={'schema':1,'fixtureOnly':True,'installed':False,'candidate':'compiled-first-party-contrast',
            'cases':{},'packages':[], 'coverage':{'RaycastAPI':'not-implemented','mountedReconciler':'not-tested',
            'publicExtensions':'not-run','productEngineDecision':'required','NodeCompatibility':'not-equivalent'}}
    with slots.owned_directory() as task:
        compiler=task/'compiler'; compiler.mkdir()
        project=task/'project'; (project/'node_modules').mkdir(parents=True)
        for entry in json.loads((FIXTURE/'packages.json').read_text())['packages']:
            destination=compiler if entry['name'].startswith('@esbuild/') else project/'node_modules/react-temp'
            destination.mkdir(exist_ok=True)
            digest=package(entry,destination)
            if entry['name']=='react':
                (destination/'package').rename(project/'node_modules/react')
                if not (project/'node_modules/react/LICENSE').is_file(): raise RuntimeError('Missing React license')
            report['packages'].append(dict(name=entry['name'],version=entry['version'],archiveSHA256=digest,license=entry['license']))
        esbuild=compiler/'package/bin/esbuild'; esbuild.chmod(0o755)
        empty=task/'empty.plist';empty.write_bytes(broker.plistlib.dumps({}))
        m0.run(['codesign','--force','--sign',identity,'--options','runtime','--timestamp=none',
                '--identifier','org.keylane.tests.runtime-m0.compiler','--entitlements',str(empty),str(esbuild)],capture_output=True)
        m0.verify_signature(esbuild,identity,{})
        if subprocess.check_output([str(esbuild),'--version'],text=True).strip()!='0.25.5': raise RuntimeError('Wrong compiler')
        node=m0.download_node(task,args.archive)
        rights={'com.apple.security.cs.allow-jit':True};node_rights=task/'node-control.plist';node_rights.write_bytes(broker.plistlib.dumps(rights))
        m0.run(['codesign','--force','--sign',identity,'--options','runtime','--timestamp=none',
                '--identifier','org.keylane.tests.runtime-m0.node-control','--entitlements',str(node_rights),str(node)],capture_output=True)
        m0.verify_signature(node,identity,rights)
        marker=task/'synthetic'; marker.write_text('fixture-only')
        app,helper,parent,entitlements=broker.build_fixture(task/'signed',identity)
        expected={'no-view':{'kind':'no-view','answer':42},'view':{'kind':'view-data','title':'M0','rows':['First party','Second row']},
                  'storage':{'kind':'storage','matched':True},'node-fs':{'kind':'node-fs','matched':True},
                  'buffer':{'kind':'buffer','text':'Zml4dHVyZQ=='},'timer':{'kind':'timer','created':True}}
        report['samples']={}
        for name in expected:
            source=FIXTURE/(name+('.tsx' if name=='view' else '.ts'))
            staged=project/source.name; staged.write_bytes(source.read_bytes())
            output=project/(name+'.js')
            m0.run([str(esbuild),str(staged),'--bundle','--platform=node','--format=iife','--minify',
                    '--define:process.env.NODE_ENV="production"','--outfile='+str(output)],capture_output=True)
            compiled=output.read_text()
            program='globalThis.__m0File='+json.dumps(str(marker))+';\n'+compiled+'\nglobalThis.__m0Result;'
            shim='const store={}; globalThis.__m0Request=s=>{const q=JSON.parse(s);if(q.op==="storage.set")store[q.key]=q.value;return JSON.stringify({ok:true,value:store[q.key]??null});};'
            control=subprocess.run([str(node),'-e',shim+program+'\nconsole.log(globalThis.__m0Result);'],capture_output=True,text=True,timeout=8,check=True)
            positive=json.loads(control.stdout)==expected[name]
            p=subprocess.Popen([str(parent)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                               text=True,start_new_session=True,env={'PATH':'/usr/bin:/bin'})
            try:
                out,_=p.communicate(json.dumps({'source':program,'scenario':'a'}),timeout=12)
                frames=[json.loads(line) for line in out.splitlines()]
                if name in ('no-view','view','storage'):
                    key={'no-view':'compiledNoView','view':'compiledReactData','storage':'compiledStorage'}[name]
                    report['cases'][key]=positive and p.returncode==0 and len(frames)==2 and json.loads(frames[1]['result'])==expected[name]
                else:
                    key={'node-fs':'nodeFS','buffer':'nodeBuffer','timer':'nodeTimer'}[name]
                    report['cases'][key+'Positive']=positive
                    report['cases'][key+'Unavailable']=p.returncode==72 and len(frames)==2 and frames[1]=={'scriptError':True}
                report['samples'][name]={'compiledBytes':len(compiled.encode()),'sourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),
                                         'bundleSHA256':hashlib.sha256(compiled.encode()).hexdigest(),'NodeControlMatched':positive,
                                         'restrictedExit':p.returncode}
            finally:
                if p.poll() is None:p.kill()
                p.wait(timeout=5);broker.confirm_helper_exit(helper)
        report['cases']['fixturesExited']=not broker.helper_pids(helper)
        m0.verify_signature(app,identity,entitlements)
        m0.verify_signature(esbuild,identity,{})
        m0.verify_signature(node,identity,rights)
        m0.run(['codesign','--verify','--strict','-R=anchor apple generic and certificate leaf = H"'+identity+'"',str(parent)],capture_output=True)
        report['signaturesVerifiedBeforeAndAfter']=True
        report['gate'],report['failures']=verdict(report['cases'])
    report['temporaryArtifactsRemoved']=True
    args.report.parent.mkdir(parents=True,exist_ok=True)
    with args.report.open('x') as file:json.dump(report,file,indent=2)
    print(json.dumps({'gate':report['gate'],'failures':report['failures'],'report':str(args.report)}))
    return 2 if report['gate']=='blocked' else 3


if __name__=='__main__':raise SystemExit(main())
