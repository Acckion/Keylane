#!/usr/bin/env python3
"""M0 alternative research only. No product engine or compatibility claim changes.

Tests a JSContext with no exported native capabilities, kernel parent identity
constraints, fresh process/context state, and parent-EOF cancellation. Never
returns a production approval: mandatory broker/compatibility work is absent.
"""
import argparse
import errno
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import selectors
import shutil
import signal
import sys
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / 'Tests/ExtensionPrototype/MacOSRuntimeM0'
spec = importlib.util.spec_from_file_location('slots', ROOT / 'scripts/verify-macos-runtime-slots.py')
slots = importlib.util.module_from_spec(spec); spec.loader.exec_module(slots)
m0 = slots.m0


REQUIRED_CASES = {
    'nativeFilePositiveControl', 'ordinaryJavaScript', 'nativeFileDenied',
    'noProcess', 'noRequire', 'noFetch', 'noObjC', 'noImportScripts', 'noWorker',
    'noReadFile', 'noShellLoad', 'noDlopen', 'constructorHasNoProcess',
    'freshInvocationState', 'wrongSignedParentRejected', 'directLaunchRejected',
    'parentDeathStopsInfiniteJS', 'disabledWatcherControlSurvives',
}


def verdict(cases):
    if not REQUIRED_CASES.issubset(cases) or any(type(cases[key]) is not bool for key in REQUIRED_CASES):
        raise RuntimeError('Missing or invalid required probe result')
    failures = sorted(name for name in REQUIRED_CASES if cases[name] is not True)
    return ('blocked', failures) if failures else ('incomplete', [])


def native_file_denied(control):
    if type(control.get('tested')) is not bool or type(control.get('allowed')) is not bool or type(control.get('errno')) is not int:
        raise RuntimeError('Invalid native control schema; numbers cannot stand in for booleans')
    return control['tested'] and not control['allowed'] and control['errno'] in (errno.EPERM, errno.EACCES)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        raise SystemExit('Requires arm64 macOS test host')
    if args.report.exists(): raise SystemExit('Refusing report overwrite')
    identity = m0.resolve_identity()
    report = dict(schema=1, fixtureOnly=True, installed=False, candidate='restricted-JavaScriptCore', cases={},
                  coverage={'RaycastNodeCompatibility': 'not-implemented', 'broker': 'not-implemented',
                            'keychain': 'not-tested', 'nativeAddon': 'not-tested',
                            'fullHostileEngineEscape': 'not-proven', 'fullContainerSanitization': 'not-tested'})
    with slots.owned_directory() as task, slots.owned_directory() as external:
        helper = task / 'Capsule.app/Contents/MacOS/helper'; helper.parent.mkdir(parents=True)
        app = task / 'Capsule.app'
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
            CFBundleIdentifier='org.keylane.tests.runtime-m0.restricted-js', CFBundleExecutable='helper',
            CFBundleName='Keylane M0 Restricted JS', CFBundlePackageType='APPL', LSUIElement=True)))
        m0.run(['xcrun','clang','-fobjc-arc','-O2','-framework','Foundation','-framework','JavaScriptCore',
                str(FIXTURE / 'RestrictedJS/Helper.m'),'-o',str(helper)])
        launcher = task / 'trusted-parent'
        m0.run(['xcrun','clang','-O2',str(FIXTURE / 'RestrictedJS/Launcher.c'),'-o',str(launcher)])
        def sign(path, identifier, **extra):
            command=['codesign','--force','--options','runtime','--timestamp=none','--sign',identity,'--identifier',identifier]
            for key,value in extra.items(): command.extend(['--'+key.replace('_','-'),str(value)])
            m0.run(command+[str(path)],capture_output=True)
        sign(launcher,'org.keylane.tests.runtime-m0.trusted-parent')
        # Team is read from this freshly verified first-party signed binary, never
        # from extension input, and is not retained in the published report.
        m0.run(['codesign','--verify','--strict',str(launcher)],capture_output=True)
        detail=m0.run(['codesign','-dv','--verbose=4',str(launcher)],capture_output=True).stderr.decode()
        team=next(line.split('=',1)[1] for line in detail.splitlines() if line.startswith('TeamIdentifier='))
        constraint=task/'parent.plist'
        constraint.write_bytes(plistlib.dumps({'signing-identifier':'org.keylane.tests.runtime-m0.trusted-parent','team-identifier':team}))
        m0.run(['codesign','--validate-constraint',str(constraint)],capture_output=True)
        sign(app,'org.keylane.tests.runtime-m0.restricted-js',entitlements=FIXTURE/'helper.entitlements',launch_constraint_parent=constraint)
        m0.verify_signature(app,identity,plistlib.loads((FIXTURE/'helper.entitlements').read_bytes()))
        secret=external/'synthetic-secret'; secret.write_text('synthetic-only')
        adjacent=task/'adjacent-marker'; adjacent.write_text('synthetic-artifact-data')
        report['cases']['nativeFilePositiveControl']=secret.read_text()=='synthetic-only'
        def invoke(source, parent=launcher, probe_file=None):
            p=subprocess.Popen([str(parent)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                               text=True,start_new_session=True,env={'PATH':'/usr/bin:/bin'})
            try:
                output,diagnostic=p.communicate(json.dumps({'source':source,'probeFile':str(probe_file or secret)}),timeout=8)
                if p.returncode != 0: raise RuntimeError(f'Capsule experiment failed: {p.returncode}; first-party diagnostic: {diagnostic[:200]}')
                frames=[json.loads(line) for line in output.splitlines()]
                if len(frames)!=2 or not frames[0].get('ready'): raise RuntimeError('Invalid fixture frames')
                return frames[0],json.loads(frames[1]['result'])
            finally:
                if p.poll() is None: p.kill()
                p.wait(timeout=5)
        ready,value=invoke('JSON.stringify({sum:[1,2,3].reduce((a,b)=>a+b,0), noProcess:typeof process==="undefined", noRequire:typeof require==="undefined", noFetch:typeof fetch==="undefined", noObjC:typeof ObjC==="undefined", noImportScripts:typeof importScripts==="undefined", noWorker:typeof Worker==="undefined", noReadFile:typeof readFile==="undefined", noShellLoad:typeof load==="undefined", noDlopen:typeof dlopen==="undefined", constructorHasNoProcess:Function("return typeof process")()==="undefined"})')
        report['cases']['ordinaryJavaScript']=value.pop('sum')==6
        report['fileControl']=ready['fileControl']
        report['cases']['nativeFileDenied']=native_file_denied(ready['fileControl'])
        report['cases'].update(value)
        artifactReady,_=invoke('JSON.stringify(true)',probe_file=adjacent)
        report['artifactAdjacentFileControl']=artifactReady['fileControl']
        # Fresh process, not clearing a few globals on a reused context.
        invoke('globalThis.syntheticPrivateValue="private-marker"; JSON.stringify(true)')
        _,fresh=invoke('JSON.stringify(typeof syntheticPrivateValue==="undefined")')
        report['cases']['freshInvocationState']=fresh
        # Keep positive signing team, change only signing identifier.
        rogue=task/'wrong-parent'; rogue.write_bytes(launcher.read_bytes()); rogue.chmod(0o755)
        sign(rogue,'org.keylane.tests.runtime-m0.wrong-parent')
        wrong=subprocess.run([str(rogue)],input=json.dumps({'source':'JSON.stringify(true)','probeFile':str(secret)}),capture_output=True,text=True,timeout=8,env={'PATH':'/usr/bin:/bin'})
        report['cases']['wrongSignedParentRejected']=wrong.returncode==137 and not wrong.stdout
        direct=subprocess.run([str(helper)],input=json.dumps({'source':'JSON.stringify(true)','probeFile':str(secret)}),capture_output=True,text=True,timeout=8,env={'PATH':'/usr/bin:/bin'})
        report['cases']['directLaunchRejected']=direct.returncode==-signal.SIGKILL and not direct.stdout
        # Build a negative-control twin with only the native EOF watcher disabled.
        # It is never selected by JS, command-line flags, a manifest or production.
        negativeRoot=task/'negative'
        negativeRoot.mkdir()
        negativeApp=negativeRoot/'Capsule.app'
        shutil.copytree(app,negativeApp)
        negativeHelper=negativeApp/'Contents/MacOS/helper'
        m0.run(['xcrun','clang','-fobjc-arc','-O2','-DM0_DISABLE_PARENT_WATCH','-framework','Foundation',
                '-framework','JavaScriptCore',str(FIXTURE/'RestrictedJS/Helper.m'),'-o',str(negativeHelper)])
        sign(negativeApp,'org.keylane.tests.runtime-m0.restricted-js',entitlements=FIXTURE/'helper.entitlements',launch_constraint_parent=constraint)
        negativeParent=negativeRoot/'trusted-parent'
        shutil.copy2(launcher,negativeParent)
        def parent_death(parent, executable):
            p=subprocess.Popen([str(parent)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
                               text=False,bufsize=0,start_new_session=True,env={'PATH':'/usr/bin:/bin'})
            child=None
            try:
                p.stdin.write(json.dumps({'source':'__m0Entered(); while(true) {}','probeFile':str(secret)}).encode())
                p.stdin.close()
                # Fixed native telemetry before and after entry; no payload text.
                frames=[]
                with selectors.DefaultSelector() as reader:
                    reader.register(p.stdout,selectors.EVENT_READ)
                    for _ in range(2):
                        if not reader.select(timeout=8): raise RuntimeError('Loop telemetry missing')
                        frames.append(json.loads(p.stdout.readline()))
                if not frames[0].get('ready') or frames[1] != {'entered':True}:
                    raise RuntimeError('Loop did not enter JavaScript')
                child=frames[0]['pid']
                time.sleep(0.05)
                if slots.snapshot(child,executable) is None: raise RuntimeError('Loop ended before cancellation')
                start=time.monotonic()
                p.kill()
                p.wait(timeout=5)
                deadline=time.monotonic()+1
                while slots.snapshot(child,executable) is not None and time.monotonic()<deadline: time.sleep(0.02)
                return dict(exited=slots.snapshot(child,executable) is None,
                            elapsedMs=round((time.monotonic()-start)*1000,1),enteredJavaScript=True)
            finally:
                if child is not None and slots.snapshot(child,executable) is not None: os.kill(child,signal.SIGKILL)
                if p.poll() is None: p.kill()
                p.wait(timeout=5)
                if child is not None:
                    deadline=time.monotonic()+3
                    while slots.snapshot(child,executable) is not None and time.monotonic()<deadline: time.sleep(0.02)
                    if slots.snapshot(child,executable) is not None: raise RuntimeError('Owned helper remains alive')
        report['parentDeath']=parent_death(launcher,helper)
        report['watcherDisabledControl']=parent_death(negativeParent,negativeHelper)
        report['cases']['parentDeathStopsInfiniteJS']=report['parentDeath']['exited']
        report['cases']['disabledWatcherControlSurvives']=not report['watcherDisabledControl']['exited']
        report['fixtureProcessCleanupConfirmed']=True
        m0.verify_signature(negativeApp,identity,plistlib.loads((FIXTURE/'helper.entitlements').read_bytes()))
        m0.verify_signature(app,identity,plistlib.loads((FIXTURE/'helper.entitlements').read_bytes()))
        report['signaturesVerifiedBeforeAndAfter']=True
        report['gate'],report['failures']=verdict(report['cases'])
    report['temporaryArtifactsRemoved']=True
    args.report.parent.mkdir(parents=True,exist_ok=True)
    with args.report.open('x') as output: json.dump(report,output,indent=2)
    print(json.dumps(dict(gate=report['gate'],failures=report['failures'],report=str(args.report))))
    return 2 if report['gate']=='blocked' else 3


if __name__=='__main__': raise SystemExit(main())
