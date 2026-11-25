#!/usr/bin/env python3
"""M0: reuse pinned #222 receipt/registry algorithms with first-party fixtures only."""
import argparse
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import platform
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('broker', ROOT/'scripts/verify-macos-broker-m0.py')
broker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(broker)
m0, slots = broker.m0, broker.slots
SOURCE_COMMIT = 'c7b419771a5196a65bd8894daa6c63fd3ce74f43'
CASES = {'sealedFirstPartyExecutes', 'sourceInjectionRejected', 'signatureRejected', 'innerDigestRejected',
         'wrongKeyRejected', 'wrongRuntimeRejected', 'wrongInstallationRejected', 'wrongCommandRejected',
         'wrongRevisionRejected', 'grantMismatchRejected', 'registryRollbackRejected', 'missingAnchorRejected',
         'ticketReplayRejected', 'disableBeforeEffectStopsChild', 'disableAfterReadWithholdsBody',
         'offOnCannotReviveOldLease', 'uninstallStopsOldChild', 'replacementStopsOldChild',
         'failedCASDoesNotReviveLease', 'fixturesExited'}


def verdict(cases):
    if not CASES.issubset(cases) or any(type(cases[name]) is not bool for name in CASES):
        raise RuntimeError('Missing/invalid receipt observation')
    failures = sorted(name for name in CASES if cases[name] is not True)
    return ('blocked', failures) if failures else ('incomplete', [])


def extract_source(task):
    # Immutable reviewed source, no download or mutable branch fallback. Fail if
    # the exact Git object is unavailable; normal CI does not run this local probe.
    ref = subprocess.check_output(['git','rev-parse',SOURCE_COMMIT+'^{commit}'],cwd=ROOT,text=True).strip()
    if ref != SOURCE_COMMIT: raise RuntimeError('Unexpected source identity')
    archive = subprocess.check_output(['git','archive',SOURCE_COMMIT,'Sources/KeylaneCore'],cwd=ROOT)
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        if any((not item.isdir() and not item.isfile()) or Path(item.name).parts[0] != 'Sources' or '..' in Path(item.name).parts for item in tar.getmembers()):
            raise RuntimeError('Unexpected source archive entry')
        tar.extractall(task,filter='data')
    files=sorted((task/'Sources/KeylaneCore').glob('*.swift'))
    if not files: raise RuntimeError('Missing pinned Core sources')
    m0.run(['swiftc','-swift-version','5','-package-name','Keylane','-parse-as-library',
            '-emit-library','-static','-emit-module','-enable-testing','-module-name','M0Store',
            '-emit-module-path',str(task/'M0Store.swiftmodule'),'-o',str(task/'libM0Store.a'),*map(str,files)],capture_output=True)
    critical=['RaycastStoreArtifactSeal.swift','RaycastStoreProtectedReceiptState.swift','RaycastStoreDiskRegistry.swift','StoreGuestRunTicket.swift']
    return {'commit':SOURCE_COMMIT,'keyFileSHA256':{name:hashlib.sha256((task/'Sources/KeylaneCore'/name).read_bytes()).hexdigest() for name in critical}}


def invoke(parent,helper,mode):
    p=subprocess.Popen([str(parent)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                       text=True,start_new_session=True,env={'PATH':'/usr/bin:/bin'})
    try:
        out,diagnostic=p.communicate(json.dumps({'source':mode,'scenario':'receipt'}),timeout=12)
        frames=[json.loads(line) for line in out.splitlines()]
        audit=json.loads(diagnostic) if diagnostic.strip().startswith('{') else None
        if audit and audit.get('memoryObservationFailed') is not False: raise RuntimeError('Memory observation failed')
        return p.returncode,frames,audit
    finally:
        if p.poll() is None: p.kill()
        p.wait(timeout=5); broker.confirm_helper_exit(helper)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report',type=Path,required=True)
    args=parser.parse_args()
    if sys.platform!='darwin' or platform.machine()!='arm64': raise SystemExit('Requires arm64 macOS')
    if args.report.exists(): raise SystemExit('Refusing report overwrite')
    identity=m0.resolve_identity()
    report=dict(schema=1,fixtureOnly=True,installed=False,candidate='pinned-store-receipt-bridge',cases={},
                coverage={'productionEnrollment':'not-connected','protectedStorage':'in-memory-CAS-fixture',
                          'sourceBuild':'fixed-first-party-bytes-not-a-build-service','persistentRestart':'not-proven',
                          'copiedProductParentAdmission':'not-proven','RaycastNodeCompatibility':'not-implemented'})
    with slots.owned_directory() as task:
        store=task/'store-source'; store.mkdir()
        report['sourceContract']=extract_source(store)
        fixture=task/'signed-fixture'; fixture.mkdir()
        app,helper,parent,entitlements=broker.build_fixture(fixture,identity,store_module=store)
        code,frames,audit=invoke(parent,helper,'valid')
        report['cases']['sealedFirstPartyExecutes']=code==0 and len(frames)==3 and frames[1]=={'entered':True} and json.loads(frames[2]['result'])=={'valid':True,'injected':False} and audit['receiptCurrent'] is True
        for mode,name in [('globalThis.injected=true; JSON.stringify(true)','sourceInjectionRejected'),
                          ('signature','signatureRejected'),('inner-digest','innerDigestRejected'),('wrong-key','wrongKeyRejected'),
                          ('wrong-runtime','wrongRuntimeRejected'),('wrong-installation','wrongInstallationRejected'),
                          ('wrong-command','wrongCommandRejected'),('wrong-revision','wrongRevisionRejected'),
                          ('grant-mismatch','grantMismatchRejected'),('registry-rollback','registryRollbackRejected'),
                          ('anchor-missing','missingAnchorRejected'),('ticket-replay','ticketReplayRejected')]:
            code,frames,_=invoke(parent,helper,mode)
            report['cases'][name]=code==0 and frames==[{'admissionRejected':True,'spawned':False}]
        for mode,name in [('disable-before','disableBeforeEffectStopsChild'),('disable-after','disableAfterReadWithholdsBody'),
                          ('off-on','offOnCannotReviveOldLease'),('uninstall','uninstallStopsOldChild'),
                          ('replace','replacementStopsOldChild'),('cas-failure','failedCASDoesNotReviveLease')]:
            code,frames,audit=invoke(parent,helper,mode)
            report['cases'][name]=code==137 and len(frames)==2 and frames[1]=={'entered':True} and audit is not None and audit['receiptCurrent'] is False and audit['receiptReplyWithheld'] is True and audit['stopConfirmed'] is True
            if mode in ('off-on','replace'):
                report['cases'][name]=report['cases'][name] and audit['freshAdmission'] is True
        report['cases']['fixturesExited']=not broker.helper_pids(helper)
        m0.verify_signature(app,identity,entitlements)
        m0.run(['codesign','--verify','--strict','-R=anchor apple generic and certificate leaf = H"'+identity+'"',str(parent)],capture_output=True)
        report['signaturesVerifiedBeforeAndAfter']=True
        report['gate'],report['failures']=verdict(report['cases'])
    report['temporaryArtifactsRemoved']=True
    args.report.parent.mkdir(parents=True,exist_ok=True)
    with args.report.open('x') as output: json.dump(report,output,indent=2)
    print(json.dumps({'gate':report['gate'],'failures':report['failures'],'report':str(args.report)}))
    return 2 if report['gate']=='blocked' else 3


if __name__=='__main__': raise SystemExit(main())
