#!/usr/bin/env python3
"""Bounded own-container plaintext observation and native crash twin, not a wipe proof."""
import argparse
import importlib.util
import json
from pathlib import Path
import platform
import subprocess
import sys
import uuid

ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('broker',ROOT/'scripts/verify-macos-broker-m0.py')
broker=importlib.util.module_from_spec(spec);spec.loader.exec_module(broker)
m0,slots=broker.m0,broker.slots
CASES={'controlWritesMarker','scannerFindsControl','controlRemoved','noObservedPlaintextAfterExecution',
       'scriptErrorContainsNoBody','noObservedPlaintextAfterError','freshContext','nativeCrashPropagated','fixturesExited'}


def verdict(cases):
    if not CASES.issubset(cases)or any(type(cases[name])is not bool for name in CASES):raise RuntimeError('Missing/invalid privacy observation')
    failures=sorted(k for k in CASES if not cases[k]);return('blocked',failures)if failures else('incomplete',[])


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--report',type=Path,required=True);args=parser.parse_args()
    if sys.platform!='darwin'or platform.machine()!='arm64':raise SystemExit('Requires arm64 macOS')
    if args.report.exists():raise SystemExit('Refusing report overwrite')
    identity=m0.resolve_identity();marker='m0-private-'+uuid.uuid4().hex
    report={'schema':1,'fixtureOnly':True,'installed':False,'candidate':'bounded-own-container-observation','cases':{},
            'coverage':{'scan':'own-Data-Library-and-tmp-no-symlinks-max16MiB','fullContainerSanitization':'not-claimed','realUserData':'not-used'}}
    with slots.owned_directory()as task:
        app,helper,parent,entitlements=broker.build_fixture(task/'audit',identity,helper_flags=['-DM0_PRIVACY_AUDIT',f'-DM0_PRIVACY_MARKER=@"{marker}"'],helper_identifier='org.keylane.tests.runtime-m0.privacy')
        crash_app,crash_helper,crash_parent,crash_entitlements=broker.build_fixture(task/'crash',identity,helper_flags=['-DM0_NATIVE_CRASH'])
        def invoke(source,parent=parent,helper=helper):
            p=subprocess.Popen([str(parent)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
            try:
                out,_=p.communicate(json.dumps({'source':source,'scenario':'a'}),timeout=12)
                return p.returncode,[json.loads(line)for line in out.splitlines()]
            finally:
                if p.poll()is None:p.kill()
                p.wait(timeout=5);broker.confirm_helper_exit(helper)
        try:
            code,frames=invoke('__m0AuditWrite');report['cases']['controlWritesMarker']=code==0 and frames[1]=={'controlWritten':True}
            code,frames=invoke('__m0AuditScan');report['cases']['scannerFindsControl']=code==0 and frames[1].get('auditComplete')is True and frames[1].get('markerFound')is True
            report['controlObservation']=frames[1]
            code,frames=invoke('__m0AuditDelete');report['cases']['controlRemoved']=code==0 and frames[1]=={'controlRemoved':True}
            invoke('globalThis.privateValue='+json.dumps(marker)+'; JSON.stringify(true);')
            code,frames=invoke('__m0AuditScan');report['cases']['noObservedPlaintextAfterExecution']=code==0 and frames[1].get('auditComplete')is True and frames[1].get('markerFound')is False
            code,frames=invoke('throw new Error('+json.dumps(marker)+');')
            report['cases']['scriptErrorContainsNoBody']=code==72 and frames[1]=={'scriptError':True} and marker not in json.dumps(frames)
            code,frames=invoke('__m0AuditScan');report['cases']['noObservedPlaintextAfterError']=code==0 and frames[1].get('auditComplete')is True and frames[1].get('markerFound')is False
            code,frames=invoke('JSON.stringify(typeof privateValue==="undefined");');report['cases']['freshContext']=code==0 and frames[1]=={'result':'true'}
            code,frames=invoke('JSON.stringify(true)',crash_parent,crash_helper)
            report['cases']['nativeCrashPropagated']=code==139 and len(frames)==1 and frames[0].get('ready')is True
        finally:
            code,frames=invoke('__m0AuditDelete')
            if code!=0 or frames[1]!={'controlRemoved':True}:raise RuntimeError('Own control marker cleanup failed')
        for bundle,rights in[(app,entitlements),(crash_app,crash_entitlements)]:m0.verify_signature(bundle,identity,rights)
        report['cases']['fixturesExited']=not broker.helper_pids(helper)and not broker.helper_pids(crash_helper)
        report['signaturesVerifiedBeforeAndAfter']=True
        report['gate'],report['failures']=verdict(report['cases'])
    report['temporaryArtifactsRemoved']=True;args.report.parent.mkdir(parents=True,exist_ok=True)
    with args.report.open('x')as file:json.dump(report,file,indent=2)
    print(json.dumps({'gate':report['gate'],'failures':report['failures'],'report':str(args.report)}));return 2 if report['gate']=='blocked'else 3


if __name__=='__main__':raise SystemExit(main())
