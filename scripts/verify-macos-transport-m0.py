#!/usr/bin/env python3
"""First-party signed M0 faults/pressure. Never approves a production runtime."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import selectors
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('broker', ROOT/'scripts/verify-macos-broker-m0.py')
broker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(broker)
m0, slots = broker.m0, broker.slots
CASES = {'fragmentedPositiveControl', 'zeroRequestRejected', 'hugeRequestRejected',
         'shortHeader1Rejected', 'shortHeader2Rejected', 'shortHeader3Rejected', 'shortBodyRejected',
         'zeroReplyRejected', 'hugeReplyRejected', 'shortReplyHeaderRejected', 'shortReplyBodyRejected',
         'invalidUTF8ReplyRejected', 'blockedRPCParentDeath', 'blockedRPCDeadline',
         'resultLimitAccepted', 'oversizedResultRejected', 'memoryWatchdogStopsAllocation',
         'observeOnlyMemoryControlSurvives', 'fixturesExited'}


def verdict(cases):
    if not CASES.issubset(cases) or any(type(cases[key]) is not bool for key in CASES):
        raise RuntimeError('Missing/invalid transport observation')
    failures = sorted(key for key in CASES if cases[key] is not True)
    return ('blocked', failures) if failures else ('incomplete', [])


def invoke(parent, helper, source, scenario='a', crash=False):
    p = subprocess.Popen([str(parent)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env={'PATH':'/usr/bin:/bin'}, start_new_session=True)
    try:
        payload = json.dumps({'source':source, 'scenario':scenario}).encode()
        if crash:
            p.stdin.write(payload); p.stdin.close(); p.stdin = None
            # No buffered readline: read the exact native held-reply marker before
            # killing only the parent. The JS thread is blocked in native RPC.
            data = bytearray()
            with selectors.DefaultSelector() as selector:
                selector.register(p.stderr, selectors.EVENT_READ)
                deadline = time.monotonic()+6
                while b'\n' not in data:
                    if time.monotonic() >= deadline or not selector.select(0.1):
                        if time.monotonic() >= deadline: raise RuntimeError('No native blocked-RPC control')
                        continue
                    chunk = os.read(p.stderr.fileno(), 1024)
                    if not chunk: raise RuntimeError('Parent exited before blocked-RPC control')
                    data.extend(chunk)
            if json.loads(data) != {'replyHeld':True}: raise RuntimeError('Unexpected fault-control event')
            p.kill()
            out, diagnostic = p.communicate(timeout=5)
        else:
            out, diagnostic = p.communicate(payload, timeout=12)
        frames = [json.loads(line) for line in out.splitlines()]
        diagnostics = [json.loads(line) for line in diagnostic.splitlines()]
        audit = next((item for item in diagnostics if item.get('audit') is True), None)
        if audit and audit.get('memoryObservationFailed') is not False:
            raise RuntimeError('Native memory observation failed')
        return p.returncode, frames, audit
    finally:
        if p.poll() is None: p.kill()
        p.wait(timeout=5)
        broker.confirm_helper_exit(helper)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform!='darwin' or platform.machine()!='arm64': raise SystemExit('Requires arm64 macOS')
    if args.report.exists(): raise SystemExit('Refusing report overwrite')
    identity = m0.resolve_identity()
    report = dict(schema=1, fixtureOnly=True, installed=False, candidate='restricted-js-transport-pressure', cases={},
                  coverage={'installationAdmission':'synthetic-only', 'memoryHardLimit':'not-proven',
                            'containerSanitization':'not-tested', 'keychain':'not-tested',
                            'RaycastNodeCompatibility':'not-implemented'},
                  memoryPolicy={'sampleMs':20,'thresholdMiB':64,'syntheticAllocationCeilingMiB':128})
    fixtures=[]
    with slots.owned_directory() as task:
        def build(name, **options):
            root=task/name; root.mkdir()
            result=broker.build_fixture(root, identity, **options)
            fixtures.append(result)
            return result[2],result[1]
        parent,helper=build('normal')
        raw_parent,raw_helper=build('raw',raw=True)
        fault_parent,fault_helper=build('reply-faults',defines=['-D','M0_REPLY_FAULTS'])
        observe_parent,observe_helper=build('observe-only',defines=['-D','M0_MEMORY_OBSERVE_ONLY'])
        code,frames,audit=invoke(raw_parent,raw_helper,'valid')
        report['cases']['fragmentedPositiveControl']=code==0 and len(frames)==3 and frames[1]=={'rawPeer':True} and frames[2]=={'result':'true'} and audit['requests']==1
        for mode,key in [('zero','zeroRequestRejected'),('huge','hugeRequestRejected'),
                         ('short-header-1','shortHeader1Rejected'),('short-header-2','shortHeader2Rejected'),
                         ('short-header-3','shortHeader3Rejected'),('short-body','shortBodyRejected')]:
            code,frames,audit=invoke(raw_parent,raw_helper,mode)
            report['cases'][key]=code==71 and len(frames)==2 and frames[1]=={'rawPeer':True} and audit['requests']==0 and audit['transportRejected'] is True
        source='__m0Entered(); __m0Request(\'{"v":1,"id":1,"op":"storage.get","key":"item"}\'); JSON.stringify(false);'
        for mode,key in [('reply-zero','zeroReplyRejected'),('reply-huge','hugeReplyRejected'),
                         ('reply-short-header','shortReplyHeaderRejected'),('reply-short-body','shortReplyBodyRejected'),
                         ('reply-utf8','invalidUTF8ReplyRejected')]:
            code,frames,audit=invoke(fault_parent,fault_helper,source,mode)
            report['cases'][key]=code==71 and len(frames)==2 and frames[1]=={'entered':True} and audit['requests']==1
        code,frames,_=invoke(fault_parent,fault_helper,source,'reply-stall',crash=True)
        report['cases']['blockedRPCParentDeath']=code==-signal.SIGKILL and len(frames)==2 and frames[1]=={'entered':True}
        code,frames,_=invoke(fault_parent,fault_helper,source,'reply-stall')
        report['cases']['blockedRPCDeadline']=code==74 and len(frames)==2 and frames[1]=={'entered':True}
        code,frames,_=invoke(parent,helper,'"x".repeat(32768)')
        report['cases']['resultLimitAccepted']=code==0 and len(frames)==2 and len(frames[1]['result'])==32768
        code,frames,_=invoke(parent,helper,'"x".repeat(32769)')
        report['cases']['oversizedResultRejected']=code==71 and len(frames)==1
        # Bounded committed-memory load, never attempt system-wide exhaustion.
        pressure='''__m0Entered(); const blocks=[]; for(let i=0;i<32;i++) {
const a=new Uint8Array(4*1024*1024); a.fill(17); blocks.push(a);
const t=Date.now()+20; while(Date.now()<t){} }
const t=Date.now()+200; while(Date.now()<t){} JSON.stringify(blocks.length);'''
        code,frames,audit=invoke(parent,helper,pressure)
        report['cases']['memoryWatchdogStopsAllocation']=code==137 and len(frames)==2 and frames[1]=={'entered':True} and audit['memoryExceeded'] is True and audit['peakResidentBytes']>64*1024*1024
        report['memoryObserved']={'enforcedPeakMiB':round(audit['peakResidentBytes']/1024/1024,1)}
        code,frames,audit=invoke(observe_parent,observe_helper,pressure)
        report['cases']['observeOnlyMemoryControlSurvives']=code==0 and len(frames)==3 and frames[1]=={'entered':True} and frames[2]=={'result':'32'} and audit['memoryExceeded'] is True
        report['memoryObserved']['observeOnlyPeakMiB']=round(audit['peakResidentBytes']/1024/1024,1)
        report['cases']['fixturesExited']=all(not broker.helper_pids(item[1]) for item in fixtures)
        for app,helper,parent,entitlements in fixtures:
            m0.verify_signature(app,identity,entitlements)
            m0.run(['codesign','--verify','--strict','-R=anchor apple generic and certificate leaf = H"'+identity+'"',str(parent)],capture_output=True)
        report['signaturesVerifiedBeforeAndAfter']=True
        report['gate'],report['failures']=verdict(report['cases'])
    report['temporaryArtifactsRemoved']=True
    args.report.parent.mkdir(parents=True,exist_ok=True)
    with args.report.open('x') as output: json.dump(report,output,indent=2)
    print(json.dumps({'gate':report['gate'],'failures':report['failures'],'report':str(args.report)}))
    return 2 if report['gate']=='blocked' else 3


if __name__=='__main__':
    raise SystemExit(main())
