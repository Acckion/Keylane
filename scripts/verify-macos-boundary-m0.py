#!/usr/bin/env python3
"""Native OS denials and signed inert compiler control for restricted-JS M0."""
import argparse
import base64
import errno
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import socket
import subprocess
import sys
import uuid

ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('compat',ROOT/'scripts/verify-macos-compatibility-m0.py')
compat=importlib.util.module_from_spec(spec);spec.loader.exec_module(compat)
broker=compat.broker;m0,slots=broker.m0,broker.slots
CASES={'hostReadControl','symlinkControl','networkControl','untrustedLibraryControl','nativeHostReadDenied',
       'nativeSymlinkDenied','nativeNetworkDenied','signedLibraryAllowed','untrustedLibraryReadableButRejected',
       'sandboxCompilerPositive','buildSourceNotExecuted','fixturesExited'}


def verdict(cases):
    if not CASES.issubset(cases)or any(type(cases[k])is not bool for k in CASES):raise RuntimeError('Missing/invalid boundary observation')
    failures=sorted(k for k in CASES if not cases[k])
    return ('blocked',failures)if failures else('incomplete',[])


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--report',type=Path,required=True)
    args=parser.parse_args()
    if sys.platform!='darwin'or platform.machine()!='arm64':raise SystemExit('Requires arm64 macOS')
    if args.report.exists():raise SystemExit('Refusing report overwrite')
    identity=m0.resolve_identity()
    report={'schema':1,'fixtureOnly':True,'installed':False,'candidate':'native-boundary-and-compiler','cases':{},
            'coverage':{'libraryValidation':'linker-ad-hoc-first-party-library-negative-control','build':'fixed-CLI-stdin-stdout-no-config-or-hooks',
                        'engineMemoryCorruption':'not-proven','thirdPartyCode':'not-run'}}
    with slots.owned_directory()as task:
        source=broker.FIXTURE/'Boundary'
        payload=task/'payload.c';payload.write_text('int M0Value(void){return 42;}\n')
        signed=task/'signed.dylib';unsigned=task/'unsigned.dylib'
        m0.run(['xcrun','clang','-dynamiclib','-O2',str(payload),'-o',str(signed)],capture_output=True)
        # Keep the linker's page signature on the untrusted library: arm64 will
        # not map a truly unsigned Mach-O even in the unrestricted control. This
        # tiny counterfactual is not an executable candidate or install signature.
        shutil.copy2(signed,unsigned)
        m0.run(['codesign','--force','--sign',identity,'--timestamp=none','--identifier','org.keylane.tests.runtime-m0.library',str(signed)],capture_output=True)
        m0.run(['codesign','--verify','--strict',str(signed)],capture_output=True)
        control=task/'control'
        m0.run(['xcrun','clang','-fobjc-arc','-O2','-framework','Foundation',str(source/'Probe.m'),'-o',str(control)],capture_output=True)
        m0.run(['codesign','--force','--sign',identity,'--timestamp=none','--identifier','org.keylane.tests.runtime-m0.boundary-control',str(control)],capture_output=True)
        app=task/'Boundary.app';helper=app/'Contents/MacOS/helper';helper.parent.mkdir(parents=True)
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.keylane.tests.runtime-m0.boundary','CFBundleExecutable':'helper','CFBundlePackageType':'APPL','LSUIElement':True}))
        m0.run(['xcrun','clang','-fobjc-arc','-O2','-framework','Foundation',str(source/'Probe.m'),'-o',str(helper)],capture_output=True)
        m0.run(['codesign','--force','--sign',identity,'--options','runtime','--timestamp=none','--entitlements',str(broker.FIXTURE/'helper.entitlements'),str(app)],capture_output=True)
        entitlements=plistlib.loads((broker.FIXTURE/'helper.entitlements').read_bytes());m0.verify_signature(app,identity,entitlements)
        host=task/'host';host.mkdir();file=host/'synthetic';file.write_text('fixture-only');link=host/'link';link.symlink_to(file)
        def invoke(binary,payload):
            p=subprocess.Popen([str(binary)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
            try:
                out,_=p.communicate(json.dumps(payload).encode(),timeout=8)
                if p.returncode!=0:raise RuntimeError('Native boundary control failed: '+str(p.returncode))
                return json.loads(out)
            finally:
                if p.poll()is None:p.kill()
                p.wait(timeout=5)
        with socket.socket()as listener:
            listener.bind(('127.0.0.1',0));listener.listen(8)
            query={'file':str(file),'link':str(link),'port':listener.getsockname()[1],
                   'signed':base64.b64encode(signed.read_bytes()).decode(),'untrusted':base64.b64encode(unsigned.read_bytes()).decode(),'tag':uuid.uuid4().hex}
            ordinary=invoke(control,query);restricted=invoke(helper,dict(query,tag=uuid.uuid4().hex))
        for native,key in [('file','hostReadControl'),('link','symlinkControl'),('network','networkControl')]:report['cases'][key]=ordinary[native]['allowed']is True
        report['cases']['untrustedLibraryControl']=ordinary['untrusted']['loaded']is True and ordinary['untrusted']['valueMatched']is True
        for native,key in [('file','nativeHostReadDenied'),('link','nativeSymlinkDenied'),('network','nativeNetworkDenied')]:
            report['cases'][key]=restricted[native]['allowed']is False and restricted[native]['errno']in(errno.EPERM,errno.EACCES)
        report['cases']['signedLibraryAllowed']=restricted['signed']['readable']is True and restricted['signed']['loaded']is True and restricted['signed']['valueMatched']is True
        report['cases']['untrustedLibraryReadableButRejected']=restricted['untrusted']['readable']is True and restricted['untrusted']['loaded']is False
        compiler=task/'compiler';compiler.mkdir();entry=json.loads((compat.FIXTURE/'packages.json').read_text())['packages'][0]
        compat.package(entry,compiler)
        build_app=task/'Build.app';build_helper=build_app/'Contents/MacOS/helper';build_helper.parent.mkdir(parents=True)
        (build_app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.keylane.tests.runtime-m0.build','CFBundleExecutable':'helper','CFBundlePackageType':'APPL','LSUIElement':True}))
        tool=build_helper.parent/'esbuild';shutil.copyfile(compiler/'package/bin/esbuild',tool);tool.chmod(0o755)
        inherited=task/'inherit.plist';inherited.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.inherit':True}))
        m0.run(['xcrun','clang','-fobjc-arc','-O2','-framework','Foundation',str(source/'Builder.m'),'-o',str(build_helper)],capture_output=True)
        for target,rights in[(tool,inherited),(build_app,broker.FIXTURE/'helper.entitlements')]:
            m0.run(['codesign','--force','--sign',identity,'--options','runtime','--timestamp=none','--entitlements',str(rights),str(target)],capture_output=True)
            m0.verify_signature(target,identity,plistlib.loads(rights.read_bytes()))
        def build(text):
            p=subprocess.Popen([str(build_helper)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
            try:
                output,diagnostic=p.communicate(text.encode(),timeout=8)
                if p.returncode!=0:raise RuntimeError('Sandbox compiler failed: '+str(p.returncode)+'; first-party diagnostic: '+diagnostic.decode(errors='replace')[:1000])
                return output.decode()
            finally:
                if p.poll()is None:os.killpg(p.pid,signal.SIGKILL)
                p.wait(timeout=5)
        output=build('const answer:number=42; globalThis.__m0Result=answer;')
        report['cases']['sandboxCompilerPositive']='42'in output and '__m0Result'in output
        escaped=host/'must-not-exist'
        malicious='import fs from "node:fs"; fs.writeFileSync('+json.dumps(str(escaped))+',"not-executed");'
        output=build(malicious)
        report['cases']['buildSourceNotExecuted']=not escaped.exists() and 'writeFileSync'in output
        m0.verify_signature(app,identity,entitlements)
        m0.verify_signature(build_app,identity,entitlements)
        m0.verify_signature(tool,identity,plistlib.loads(inherited.read_bytes()))
        report['cases']['fixturesExited']=not broker.helper_pids(helper)and not broker.helper_pids(tool)and not broker.helper_pids(build_helper)
        report['signaturesVerifiedBeforeAndAfter']=True
        report['gate'],report['failures']=verdict(report['cases'])
    report['temporaryArtifactsRemoved']=True
    args.report.parent.mkdir(parents=True,exist_ok=True)
    with args.report.open('x')as output:json.dump(report,output,indent=2)
    print(json.dumps({'gate':report['gate'],'failures':report['failures'],'report':str(args.report)}))
    return 2 if report['gate']=='blocked'else 3


if __name__=='__main__':raise SystemExit(main())
