#!/usr/bin/env python3
"""M1 first batch: signed offline multifile compiler, inert inputs and cancellation.

First-party fixtures only. Exit 3=incomplete M1, 2=failed slice. Never installs.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import sys
import tarfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('broker', ROOT/'scripts/verify-macos-broker-m0.py')
broker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(broker)
m0, slots = broker.m0, broker.slots
CASES = {'multifileExecutes', 'snapshotDependencyExecutes', 'repeatDeterministic', 'configIgnored',
         'sourceNotExecuted', 'lifecycleRejected', 'unsafePathRejected', 'caseAliasRejected',
         'nativeRejected', 'unsupportedImportRejected', 'wrongProfileRejected',
         'escapedImportRejected', 'cancelStopsCompiler', 'cancelCleansScratch',
         'successfulBuildCleansScratch', 'failedBuildCleansScratch', 'fixturesExited'}


def verdict(cases):
    if any(type(cases.get(key)) is not bool for key in CASES):
        raise ValueError('Missing/non-boolean M1 observation')
    failures = sorted(key for key in CASES if not cases[key])
    return ('blocked', failures) if failures else ('incomplete', [])


def compiler(archive, destination):
    entry = json.loads((broker.FIXTURE/'Compatibility/packages.json').read_text())['packages'][0]
    data = archive.read_bytes()
    if len(data) > 16 * 1024 * 1024 or 'sha512-' + base64.b64encode(hashlib.sha512(data).digest()).decode() != entry['integrity']:
        raise ValueError('Pinned compiler archive mismatch')
    with tarfile.open(archive) as tar:
        member = tar.getmember('package/bin/esbuild')
        if not member.isfile() or member.size > 16 * 1024 * 1024:
            raise ValueError('Invalid compiler archive member')
        destination.write_bytes(tar.extractfile(member).read())
    destination.chmod(0o755)
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler-archive', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        raise SystemExit('Requires arm64 macOS')
    if args.report.exists():
        raise SystemExit('Refusing report overwrite')
    identity = m0.resolve_identity()
    report = dict(schema=1, fixtureOnly=True, installed=False, cases={},
                  coverage={'phase':'M1-first-batch', 'productEnrollment':'pending', 'StoreAdapter':'pending',
                            'installationTransactions':'pending', 'publicExtensions':'not-run'})
    with slots.owned_directory() as task:
        app = task/'Build.app'; helper = app/'Contents/MacOS/helper'
        helper.parent.mkdir(parents=True)
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
            CFBundleIdentifier='org.keylane.tests.runtime-m1.build', CFBundleExecutable='helper',
            CFBundlePackageType='APPL', LSUIElement=True)))
        tool = helper.parent/'esbuild'
        report['compilerArchiveSHA256'] = compiler(args.compiler_archive, tool)
        rights = task/'inherit.plist'
        rights.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.inherit':True}))
        m0.run(['swiftc','-package-name','Keylane','-parse-as-library','-DM1_FIXTURE','-target','arm64-apple-macos26.0','-O',
                str(ROOT/'Sources/KeylaneCore/MacOSExtensionBuild.swift'),
                str(ROOT/'Sources/KeylaneExtensionBuildHelper/Build.swift'),'-o',str(helper)], capture_output=True)
        for binary, entitlement in [(tool, rights), (app, broker.FIXTURE/'helper.entitlements')]:
            m0.run(['codesign','--force','--sign',identity,'--options','runtime','--timestamp=none',
                    '--entitlements',str(entitlement),str(binary)], capture_output=True)
            m0.verify_signature(binary,identity,plistlib.loads(entitlement.read_bytes()))
        recipe = dict(schema=1, policy='restricted-jsc-build-v1', target='darwin-arm64', compilerVersion='0.25.5',
                      compilerSHA256=hashlib.sha256(tool.read_bytes()).hexdigest(),helperSHA256=hashlib.sha256(helper.read_bytes()).hexdigest())
        eval_app, eval_helper, parent, entitlements = broker.build_fixture(task/'eval',identity)

        def files(extra=None):
            result = {'package.json':'{"name":"first-party-build"}',
                      'src/main.ts':'import {answer} from "./value";globalThis.__m1Answer=answer;',
                      'src/value.ts':'export const answer:number=42;'}
            result.update(extra or {})
            return result

        def request(source, profile=None):
            return dict(id=str(uuid.uuid4()), recipe=profile or recipe,
                        plan=dict(files=[dict(path=p,body=base64.b64encode(b.encode() if isinstance(b,str) else b).decode())
                                         for p,b in source.items()],entries=['src/main.ts']))

        def invoke(query, cancel=False):
            r, w = os.pipe()
            # Only the one first-party descriptor is made inheritable. All other
            # Python-created descriptors retain CLOEXEC. No forked threads here.
            def inherited_parent():
                os.dup2(r,3)
                os.set_inheritable(3,True) # dup2(fd,fd) must also clear CLOEXEC
            p = subprocess.Popen([str(helper)], stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                                 close_fds=False, preexec_fn=inherited_parent, env={'PATH':'/usr/bin:/bin'})
            os.close(r)
            observed = False
            try:
                payload = json.dumps(query).encode()
                if cancel:
                    p.stdin.write(payload); p.stdin.close(); p.stdin = None
                    end = time.monotonic() + 8
                    while time.monotonic() < end:
                        if broker.helper_pids(tool):
                            observed = True; break
                        if p.poll() is not None:break
                        time.sleep(0.005)
                    os.close(w); w = None
                    out, error = p.communicate(timeout=8)
                else:
                    out,error = p.communicate(payload,timeout=25)
                audit = json.loads(error) if error else None
                report.setdefault('observations',[]).append({'exit':p.returncode,'hasReply':bool(out),'audit':audit})
                return p.returncode, json.loads(out) if out else None, audit, observed
            finally:
                if w is not None:os.close(w)
                if p.poll() is None:
                    try:p.wait(timeout=5)
                    except subprocess.TimeoutExpired:p.kill()
                p.wait(timeout=5)
                broker.confirm_helper_exit(tool)

        def evaluate(reply):
            source = base64.b64decode(reply['commands'][0]['body']).decode()+'\nJSON.stringify(globalThis.__m1Answer);'
            p = subprocess.Popen([str(parent)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                out,_ = p.communicate(json.dumps({'source':source,'scenario':'a'}),timeout=12)
                frames = [json.loads(line) for line in out.splitlines()]
                return p.returncode == 0 and json.loads(frames[-1]['result']) == 42
            finally:
                if p.poll() is None:p.kill()
                p.wait(timeout=5);broker.confirm_helper_exit(eval_helper)

        q = request(files()); code, good, audit,_ = invoke(q)
        report['cases']['multifileExecutes'] = code == 0 and evaluate(good)
        report['cases']['successfulBuildCleansScratch'] = audit == {'scratchRemoved':True,'cancelled':False}
        code,again,_,_ = invoke(request(files()))
        report['cases']['repeatDeterministic'] = code == 0 and good['commands'] == again['commands'] and good['projectDigest'] == again['projectDigest']
        dependency = files({'src/main.ts':'import {answer} from "example";globalThis.__m1Answer=answer;',
                            'node_modules/example/package.json':'{"name":"example","version":"1.0.0","main":"index.js"}',
                            'node_modules/example/index.js':'export const answer=42;'})
        code,body,_,_ = invoke(request(dependency))
        report['cases']['snapshotDependencyExecutes'] = code == 0 and evaluate(body)
        marker = task/'must-not-exist'
        code,body,_,_ = invoke(request(files({'esbuild.config.js':'require("fs").writeFileSync('+json.dumps(str(marker))+',"bad");',
                                             'tsconfig.json':'{"compilerOptions":{'})))
        report['cases']['configIgnored'] = code == 0 and evaluate(body) and not marker.exists()
        code,body,_,_ = invoke(request(files({'src/main.ts':'while(true){}'})))
        report['cases']['sourceNotExecuted'] = code == 0 and b'while' in base64.b64decode(body['commands'][0]['body'])
        code,_,audit,_ = invoke(request(files({'src/main.ts':'import fs from "node:fs";fs.writeFileSync('+json.dumps(str(marker))+',"bad");'})))
        report['cases']['unsupportedImportRejected'] = code == 70 and not marker.exists()
        report['cases']['failedBuildCleansScratch'] = audit == {'scratchRemoved':True,'cancelled':False}
        negatives = [('lifecycleRejected',files({'package.json':'{"scripts":{"postinstall":"touch marker"}}'}),None),
                     ('unsafePathRejected',files({'../escape.ts':'bad'}),None),
                     ('caseAliasRejected',files({'SRC/other.ts':'bad'}),None),
                     ('nativeRejected',files({'assets/fake':b'\x7fELF'}),None),
                     ('wrongProfileRejected',files(),dict(recipe,compilerSHA256='0'*64))]
        for name,source,profile in negatives:
            code,_,_,_ = invoke(request(source,profile));report['cases'][name] = code == 70
        escape = request(files())
        escape['plan']['files'] = request(files({'src/main.ts':'import x from "../../keylane-m1-neighbor-'+escape['id'].upper()+'.js";globalThis.__m1Answer=x;'}))['plan']['files']
        code,_,audit,_ = invoke(escape)
        report['cases']['escapedImportRejected'] = code == 70 and isinstance(audit,dict) and audit.get('scratchRemoved') is True and audit.get('outsideInputRead') is True
        heavy = '\n'.join('export const v'+str(i)+'='+str(i)+';' for i in range(90000))
        code,_,audit,observed = invoke(request(files({'src/main.ts':heavy})),cancel=True)
        report['cases']['cancelStopsCompiler'] = observed and code == 75 and not broker.helper_pids(tool)
        report['cases']['cancelCleansScratch'] = code == 75 and audit == {'scratchRemoved':True,'cancelled':True}
        report['cases']['fixturesExited'] = not broker.helper_pids(helper) and not broker.helper_pids(tool) and not broker.helper_pids(eval_helper)
        for binary,entitlement in [(tool,rights),(app,broker.FIXTURE/'helper.entitlements')]:
            m0.verify_signature(binary,identity,plistlib.loads(entitlement.read_bytes()))
        m0.verify_signature(eval_app,identity,entitlements)
        report['signaturesVerifiedBeforeAndAfter'] = True
        report['gate'],report['failures'] = verdict(report['cases'])
    report['temporaryArtifactsRemoved'] = True
    args.report.parent.mkdir(parents=True,exist_ok=True)
    with args.report.open('x') as output:json.dump(report,output,indent=2)
    print(json.dumps({'gate':report['gate'],'failures':report['failures'],'report':str(args.report)}))
    return 2 if report['gate']=='blocked' else 3


if __name__=='__main__':raise SystemExit(main())
