#!/usr/bin/env python3
"""M0 first-party broker experiment, not a Store installer or production runtime."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / 'Tests/ExtensionPrototype/MacOSRuntimeM0'
spec = importlib.util.spec_from_file_location('slots', ROOT / 'scripts/verify-macos-runtime-slots.py')
slots = importlib.util.module_from_spec(spec)
spec.loader.exec_module(slots)
m0 = slots.m0
CASES = {'boundA', 'boundB', 'namespaceWritesIsolated', 'ownerSpoofRejected', 'requestReplayRejected',
         'nativeMalformedRejected', 'boundsRejected', 'offOnRejectsPending', 'replaceRejectsPending',
         'uninstallRejectsPending', 'readRevocationWithholdsReply', 'closedBindingWithholdsReply',
         'wrongSealRejectedBeforeSpawn', 'wrongParentRejected', 'frameBudgetTerminates',
         'nativeDeadlineStopsLoop', 'fixtureProcessesExited'}


def helper_pids(helper):
    # Test cleanup only: exact executable under this run's owned temporary root.
    # This is not a production process-tree supervisor.
    result = subprocess.run(['ps', '-ww', '-axo', 'pid=,stat=,args='], check=True,
                            capture_output=True, text=True)
    found = []
    for row in result.stdout.splitlines():
        fields = row.split(None, 2)
        if len(fields) == 3 and not fields[1].startswith('Z') and Path(fields[2].split(' ', 1)[0]).resolve() == helper.resolve():
            found.append(int(fields[0]))
    return found


def confirm_helper_exit(helper):
    deadline = time.monotonic() + 3
    while True:
        remaining = helper_pids(helper)
        if not remaining:
            return
        if time.monotonic() >= deadline:
            # Refuse a pass, but clean up only verified first-party fixtures.
            for pid in remaining:
                if slots.snapshot(pid, helper) is not None:
                    os.kill(pid, signal.SIGKILL)
            raise RuntimeError('Owned helper did not exit without test-controller cleanup')
        time.sleep(0.03)


def verdict(cases):
    if not CASES.issubset(cases) or any(type(cases[key]) is not bool for key in CASES):
        raise RuntimeError('Missing/invalid broker observation')
    failures = sorted(key for key in CASES if not cases[key])
    return ('blocked', failures) if failures else ('incomplete', [])


def build_fixture(task, identity, *, raw=False, defines=(), store_module=None, helper_flags=(), helper_identifier='org.keylane.tests.runtime-m0.broker-helper'):
    app = task / 'Capsule.app'
    helper = app / 'Contents/MacOS/helper'
    helper.parent.mkdir(parents=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier=helper_identifier, CFBundleExecutable='helper',
        CFBundleName='Keylane M0 Broker', CFBundlePackageType='APPL', LSUIElement=True)))
    flags = ['-DM0_BROKER', *helper_flags]
    sources = [str(FIXTURE/'RestrictedJS/Helper.m')]
    if raw:
        flags.append('-DM0_RAW_PEER')
        sources.append(str(FIXTURE/'Transport/RawPeer.m'))
    m0.run(['xcrun', 'clang', '-O2', '-fobjc-arc', *flags, '-framework', 'Foundation',
            '-framework', 'JavaScriptCore', *sources, '-o', str(helper)])
    parent = task / 'broker-parent'
    memory = task / 'memory.o'
    m0.run(['xcrun', 'clang', '-O2', '-c', str(FIXTURE/'Transport/MemoryGuard.c'), '-o', str(memory)])
    receipt_sources, receipt_flags = [], []
    if store_module is not None:
        receipt_sources = [str(FIXTURE/'Receipt/Gate.swift')]
        receipt_flags = ['-D', 'M0_RECEIPT', '-package-name', 'Keylane', '-I', str(store_module),
                         str(store_module/'libM0Store.a'), '-lsqlite3', '-lz']
    m0.run(['swiftc', '-swift-version', '5', '-O', *defines, *receipt_flags,
            '-import-objc-header', str(FIXTURE/'Transport/MemoryGuard.h'),
            str(FIXTURE/'Broker/Authority.swift'), str(FIXTURE/'Broker/FrameChannel.swift'),
            str(FIXTURE/'Broker/Parent.swift'), *receipt_sources, str(memory), '-o', str(parent)])
    identifier = 'org.keylane.tests.runtime-m0.broker-parent'
    m0.run(['codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp=none',
            '--identifier', identifier, str(parent)], capture_output=True)
    m0.run(['codesign', '--verify', '--strict', '-R=anchor apple generic and certificate leaf = H"'+identity+'"', str(parent)], capture_output=True)
    detail = m0.run(['codesign', '-dv', '--verbose=4', str(parent)], capture_output=True).stderr.decode()
    team = next(line.split('=',1)[1] for line in detail.splitlines() if line.startswith('TeamIdentifier='))
    constraint = task / 'parent.plist'
    constraint.write_bytes(plistlib.dumps({'signing-identifier': identifier, 'team-identifier': team}))
    m0.run(['codesign', '--validate-constraint', str(constraint)], capture_output=True)
    m0.run(['codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp=none',
            '--entitlements', str(FIXTURE/'helper.entitlements'), '--launch-constraint-parent', str(constraint), str(app)], capture_output=True)
    entitlements = plistlib.loads((FIXTURE/'helper.entitlements').read_bytes())
    m0.verify_signature(app, identity, entitlements)
    return app, helper, parent, entitlements


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        raise SystemExit('Requires arm64 macOS test host')
    if args.report.exists():
        raise SystemExit('Refusing report overwrite')
    identity = m0.resolve_identity()
    report = dict(schema=1, candidate='restricted-js-broker', fixtureOnly=True, installed=False, cases={},
                  authorityRoot='synthetic signed-parent records, not product Store/Registry',
                  coverage={'realInstallationAdmission': 'not-connected', 'diskStorageMigration': 'not-implemented',
                            'RaycastNodeCompatibility': 'not-implemented', 'keychain': 'not-tested',
                            'rawTransportCorruption': 'not-tested', 'memoryExhaustion': 'not-tested'})
    with slots.owned_directory() as task:
        app, helper, parent, entitlements = build_fixture(task, identity)
        prefix = 'const req=(id,op="storage.get",key="item",value)=>{const q={v:1,id,op,key}; if(value!==undefined)q.value=value;return JSON.parse(__m0Request(JSON.stringify(q)));};'
        def invoke(source, scenario, executable=parent):
            p = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True, start_new_session=True, env={'PATH':'/usr/bin:/bin'})
            try:
                out, diagnostic = p.communicate(json.dumps({'source': source, 'scenario': scenario}), timeout=12)
                frames = [json.loads(line) for line in out.splitlines()]
                audit = json.loads(diagnostic) if diagnostic.strip().startswith('{') else None
                return p.returncode, frames, audit
            finally:
                if p.poll() is None:
                    p.kill()
                p.wait(timeout=5) # closes liveness writer; helper watcher owns exit
                confirm_helper_exit(helper)
        source = prefix + '''
const first=req(1); const written=req(2,"storage.set","item","new-a");
const owner=JSON.parse(__m0Request(JSON.stringify({v:1,id:3,op:"storage.get",key:"item",owner:"b"})));
const replay=req(2); const malformed=JSON.parse(__m0Request("{"));
const path=req(3,"storage.get","../b/item"); const huge=req(3,"storage.set","item","x".repeat(513));
const numeric=JSON.parse(__m0Request(JSON.stringify({v:1,id:true,op:"storage.get",key:"item"})));
const oversized=JSON.parse(__m0Request(" ".repeat(4097))); const final=req(3);
JSON.stringify({boundA:first.ok&&first.value==="synthetic-a",namespaceWritesIsolated:written.ok&&final.value==="new-a",
ownerSpoofRejected:!owner.ok&&!JSON.stringify(owner).includes("synthetic-b"),requestReplayRejected:!replay.ok,
nativeMalformedRejected:!malformed.ok&&!numeric.ok,boundsRejected:!path.ok&&!huge.ok&&!oversized.ok});'''
        code, frames, audit = invoke(source, 'a')
        if code != 0 or len(frames) != 2 or not audit or audit['otherNamespaceIntact'] is not True:
            raise RuntimeError('Positive broker A control failed')
        report['cases'].update(json.loads(frames[1]['result']))
        code, frames, audit = invoke(prefix+'const r=req(1); JSON.stringify(r.ok&&r.value==="synthetic-b");', 'b')
        report['cases']['boundB'] = code == 0 and len(frames)==2 and json.loads(frames[1]['result']) is True and audit['otherNamespaceIntact'] is True
        for scenario, name in [('off-on','offOnRejectsPending'), ('replace','replaceRejectsPending'), ('uninstall','uninstallRejectsPending'),
                               ('read-revoke','readRevocationWithholdsReply'), ('close','closedBindingWithholdsReply')]:
            # get result is already prepared/executed for publication-race modes.
            source = prefix+'const a=req(1); const b=req(2); JSON.stringify(!a.ok&&!b.ok&&!JSON.stringify([a,b]).includes("synthetic-a"));'
            code, frames, audit = invoke(source, scenario)
            report['cases'][name] = code==0 and len(frames)==2 and json.loads(frames[1]['result']) is True and audit['otherNamespaceIntact'] is True
        code, frames, _ = invoke('JSON.stringify(false)', 'bad-admission')
        report['cases']['wrongSealRejectedBeforeSpawn'] = code==0 and frames==[{'admissionRejected':True,'spawned':False}]
        rogue = task/'wrong-parent'
        rogue.write_bytes(parent.read_bytes()); rogue.chmod(0o755)
        m0.run(['codesign','--force','--sign',identity,'--options','runtime','--timestamp=none',
                '--identifier','org.keylane.tests.runtime-m0.wrong-broker-parent',str(rogue)],capture_output=True)
        code, frames, _ = invoke(prefix+'JSON.stringify(req(1));', 'a', rogue)
        report['cases']['wrongParentRejected'] = code==137 and not frames
        code, frames, audit = invoke(prefix+'for(let i=1;i<=33;i++)req(i); JSON.stringify(false);', 'a')
        report['cases']['frameBudgetTerminates'] = code==137 and len(frames)==1 and audit['requests']==32
        code, frames, _ = invoke('__m0Entered(); while(true){}', 'a')
        report['cases']['nativeDeadlineStopsLoop'] = code==74 and len(frames)==2 and frames[0].get('ready') is True and frames[1]=={'entered':True}
        report['cases']['fixtureProcessesExited'] = not helper_pids(helper)
        m0.verify_signature(app, identity, entitlements)
        m0.run(['codesign','--verify','--strict','-R=anchor apple generic and certificate leaf = H"'+identity+'"',str(parent)],capture_output=True)
        report['signaturesVerifiedBeforeAndAfter'] = True
        report['gate'], report['failures'] = verdict(report['cases'])
    report['temporaryArtifactsRemoved'] = True
    args.report.parent.mkdir(parents=True, exist_ok=True)
    with args.report.open('x') as output:
        json.dump(report, output, indent=2)
    print(json.dumps(dict(gate=report['gate'],failures=report['failures'],report=str(args.report))))
    return 2 if report['gate']=='blocked' else 3


if __name__=='__main__':
    raise SystemExit(main())
