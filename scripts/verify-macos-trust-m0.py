#!/usr/bin/env python3
"""M0 native identity and persistent CAS primitives. Synthetic Keychain slot only."""
import argparse
import contextlib
import tempfile
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import selectors
import shutil
import subprocess
import sys
import uuid
import time
from types import SimpleNamespace

ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('broker',ROOT/'scripts/verify-macos-broker-m0.py')
broker=importlib.util.module_from_spec(spec);spec.loader.exec_module(broker)
m0,slots=broker.m0,broker.slots
CASES={'createdOwnedItem','authorizedRead','persistentAfterRestart','oneCASWinner','oldValueCannotReplay',
       'wrongClientRejected','wrongServerRejected','copiedClientRejected','copiedServerRejected',
       'replacedLockRejected','missingItemNoReset','sandboxKeychainNotReadable','nativeForeignKeychainNotReadable',
       'ownedItemRemoved','fixturesExited'}
CASES.update({'peerVerificationNegativeControl','sandboxPeerNotReadable','missingItemCannotReenroll','missingItemPreventsStartup','authorizedAfterRogue'})


def verdict(cases):
    if not CASES.issubset(cases) or any(type(cases[name]) is not bool for name in CASES):
        raise RuntimeError('Missing/invalid trust observation')
    failures=sorted(name for name in CASES if not cases[name])
    return ('blocked',failures) if failures else ('incomplete',[])


@contextlib.contextmanager
def trust_directory():
    task=Path(tempfile.mkdtemp(prefix='keylane-m0-trust-',dir='/private/tmp'))
    try:
        yield task
    finally:
        if (task/'cleanup-pending.json').exists():
            raise RuntimeError('Synthetic cleanup pending; exact identity and recovery binary retained at '+str(task))
        shutil.rmtree(task)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report',type=Path,required=True)
    args=parser.parse_args()
    if sys.platform!='darwin' or platform.machine()!='arm64':raise SystemExit('Requires arm64 macOS')
    if args.report.exists():raise SystemExit('Refusing report overwrite')
    identity=m0.resolve_identity()
    report={'schema':1,'fixtureOnly':True,'installed':False,'candidate':'native-persistent-trust-primitives','cases':{},
            'coverage':{'backend':'legacy-Keychain-ACL-research-only','productEnrollment':'not-connected','state':'synthetic-opaque-bytes',
                        'codeIdentity':'OS-XPC-requirements','storage':'explicit-item-only-no-enumeration'}}
    with trust_directory() as task:
        server=task/'server'; client=task/'client'; enroll=server; foreign=task/'foreign'
        root=task/'authority';root.mkdir(mode=0o700)
        lock=root/'authority.lock';lock.write_bytes(b'');lock.chmod(0o600)
        inode=lock.stat();parent=root.stat()
        clientID='org.keylane.tests.runtime-m0.trust-client';serverID='org.keylane.tests.runtime-m0.trust-server'
        def requirement(identifier):return 'anchor apple generic and identifier "'+identifier+'" and certificate leaf = H"'+identity+'"'
        def literal(value):return '@'+json.dumps(str(value))
        service='org.keylane.tests.runtime-m0.synthetic.'+uuid.uuid4().hex
        mach=service.replace('.synthetic.','.trust-service.')
        header=task/'Profile.h'
        header.write_text('\n'.join(['#define M0_MACH_NAME '+literal(mach),'#define M0_SERVICE '+literal(service),'#define M0_INITIAL @"synthetic-head-1"',
            '#define M0_SERVER_PATH '+literal(server),'#define M0_CLIENT_PATH '+literal(client),
            '#define M0_LOCK_ROOT '+literal(root),'#define M0_LOCK_INODE '+str(inode.st_ino),
            '#define M0_LOCK_DEVICE '+str(inode.st_dev),'#define M0_ROOT_INODE '+str(parent.st_ino),
            '#define M0_ROOT_DEVICE '+str(parent.st_dev),'#define M0_CLIENT_REQUIREMENT '+literal(requirement(clientID)),
            '#define M0_SERVER_REQUIREMENT '+literal(requirement(serverID))])+'\n')
        source=broker.FIXTURE/'Trust/Trust.m'
        def sign(binary,identifier,entitlements=None):
            args=['codesign','--force','--sign',identity,'--identifier',identifier,'--options','runtime','--timestamp=none']
            if entitlements:args+=['--entitlements',str(entitlements)]
            m0.run(args+[str(binary)],capture_output=True)
            m0.run(['codesign','--verify','--strict','-R='+requirement(identifier),str(binary)],capture_output=True)
        def build(binary,identifier,defines):
            m0.run(['xcrun','clang','-fobjc-arc','-O2','-I',str(task),*['-D'+name for name in defines],
                    '-framework','Foundation','-framework','Security',str(source),'-o',str(binary)],capture_output=True)
            sign(binary,identifier)
        build(server,serverID,['M0_TRUST_SERVER=1'])
        build(client,clientID,['M0_TRUST_CLIENT=1'])
        build(foreign,'org.keylane.tests.runtime-m0.foreign-server',['M0_TRUST_SERVER=1','M0_TRUST_FOREIGN_SERVER=1'])
        unverified=task/'unverified-client'
        build(unverified,clientID,['M0_TRUST_CLIENT=1','M0_TRUST_TEST_UNVERIFIED=1'])
        native=task/'native-keychain'
        build(native,'org.keylane.tests.runtime-m0.foreign-reader',[])
        sandbox_app=task/'SandboxReader.app';sandbox=sandbox_app/'Contents/MacOS/helper'
        sandbox.parent.mkdir(parents=True);shutil.copyfile(native,sandbox);sandbox.chmod(0o755)
        (sandbox_app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.keylane.tests.runtime-m0.sandbox-reader',
            'CFBundleExecutable':'helper','CFBundlePackageType':'APPL','LSUIElement':True}))
        sign(sandbox_app,'org.keylane.tests.runtime-m0.sandbox-reader',broker.FIXTURE/'helper.entitlements')
        peer_app=task/'SandboxPeer.app';peer=peer_app/'Contents/MacOS/helper';peer.parent.mkdir(parents=True)
        m0.run(['xcrun','clang','-fobjc-arc','-O2','-I',str(task),'-DM0_TRUST_CLIENT=1','-DM0_TRUST_TEST_SKIP_PATH=1',
                '-framework','Foundation','-framework','Security',str(source),'-o',str(peer)],capture_output=True)
        (peer_app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.keylane.tests.runtime-m0.sandbox-peer',
            'CFBundleExecutable':'helper','CFBundlePackageType':'APPL','LSUIElement':True}))
        sign(peer_app,'org.keylane.tests.runtime-m0.sandbox-peer',broker.FIXTURE/'helper.entitlements')
        def once(binary,arguments=(),payload=None):
            r=subprocess.run([str(binary),*arguments],input=None if payload is None else json.dumps(payload),
                             text=True,capture_output=True,timeout=8,env={'PATH':'/usr/bin:/bin'})
            value=json.loads(r.stdout) if r.stdout.strip() else None
            return r.returncode,value
        def start(binary,secondary=False):
            label=mach+('.foreign' if binary==foreign else '.secondary' if secondary else '')
            config=task/(label+'.plist')
            log=task/(label+'.log')
            config.write_bytes(plistlib.dumps({'Label':label,'ProgramArguments':[str(binary)]+(['secondary']if secondary else []),
                'MachServices':{label:True},'RunAtLoad':True,'StandardOutPath':str(log),'StandardErrorPath':str(log)}))
            target='gui/'+str(os.getuid())+'/'+label
            result=subprocess.run(['launchctl','bootstrap','gui/'+str(os.getuid()),str(config)],capture_output=True,text=True)
            if result.returncode!=0:raise RuntimeError('Cannot bootstrap owned test XPC service')
            job=SimpleNamespace(target=target,pid=None)
            try:
                deadline=time.monotonic()+8
                while time.monotonic()<deadline:
                    state=subprocess.run(['launchctl','print',target],capture_output=True,text=True)
                    if state.returncode!=0:raise RuntimeError('Owned service disappeared')
                    for line in state.stdout.splitlines():
                        if line.strip().startswith('pid = '):job.pid=int(line.split('=',1)[1])
                    if log.exists() and '\"listening\":true' in log.read_text().replace(' ',''):
                        return job,label
                    time.sleep(0.05)
                raise RuntimeError('Owned XPC service not ready')
            except BaseException:
                stop(job);raise
        def stop(job):
            subprocess.run(['launchctl','bootout',job.target],capture_output=True)
            deadline=time.monotonic()+5
            while subprocess.run(['launchctl','print',job.target],capture_output=True).returncode==0:
                if time.monotonic()>=deadline:raise RuntimeError('Owned service remains registered')
                time.sleep(0.05)
        def call(endpoint,mode='read',**values):return once(client,payload=dict(endpoint=endpoint,mode=mode,**values))[1]
        processes=[];provision_attempted=False
        try:
            (task/'cleanup-pending.json').write_text(json.dumps({'service':service,'account':'receipt-head','binary':str(server)}))
            provision_attempted=True # cleanup even if result parsing fails after successful creation
            code,value=once(enroll,['create']);created=bool(value and value.get('created') is True)
            if not created:raise RuntimeError('Cannot provision synthetic Keychain item; status='+str(None if value is None else value.get('status')))
            report['cases']['createdOwnedItem']=code==0
            p,endpoint=start(server);processes.append(p)
            value=call(endpoint);report['cases']['authorizedRead']=value.get('ok') is True and value['value']=='synthetic-head-1'
            report['cases']['nativeForeignKeychainNotReadable']=once(native)[1]['allowed'] is False
            report['cases']['sandboxKeychainNotReadable']=once(sandbox)[1]['allowed'] is False
            report['cases']['sandboxPeerNotReadable']=once(peer,payload=dict(endpoint=endpoint,mode='read'))[1].get('peerRejected') is True
            second,second_endpoint=start(server,secondary=True);processes.append(second)
            a=subprocess.Popen([str(client)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            b=subprocess.Popen([str(client)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            pa=json.dumps(dict(endpoint=endpoint,mode='swap',expected='synthetic-head-1',replacement='synthetic-head-2'))
            pb=json.dumps(dict(endpoint=second_endpoint,mode='swap',expected='synthetic-head-1',replacement='synthetic-head-3'))
            a.stdin.write(pa);a.stdin.close();a.stdin=None;b.stdin.write(pb);b.stdin.close();b.stdin=None
            ra=json.loads(a.communicate(timeout=8)[0]);rb=json.loads(b.communicate(timeout=8)[0])
            report['cases']['oneCASWinner']=p.pid is not None and second.pid is not None and p.pid!=second.pid and a.returncode==0 and b.returncode==0 and sorted([ra.get('swapped'),rb.get('swapped')])==[False,True]
            stop(second)
            current=call(endpoint)['value'];stop(p)
            p,endpoint=start(server);processes.append(p)
            report['cases']['persistentAfterRestart']=call(endpoint)['value']==current and current in ('synthetic-head-2','synthetic-head-3')
            report['cases']['oldValueCannotReplay']=call(endpoint,'swap',expected='synthetic-head-1',replacement='rollback').get('swapped') is False
            sign(client,'org.keylane.tests.runtime-m0.wrong-client')
            report['cases']['wrongClientRejected']=call(endpoint).get('peerRejected') is True
            sign(client,clientID)
            report['cases']['authorizedAfterRogue']=call(endpoint).get('ok') is True
            f,foreign_endpoint=start(foreign);processes.append(f)
            report['cases']['wrongServerRejected']=call(foreign_endpoint).get('peerRejected') is True
            code,value=once(unverified,payload=dict(endpoint=foreign_endpoint,mode='read'))
            report['cases']['peerVerificationNegativeControl']=code==0 and value.get('ok') is False and 'peerRejected'not in value
            stop(f)
            copied=task/'copied-client';shutil.copy2(client,copied)
            code,value=once(copied,payload=dict(endpoint=endpoint,mode='read'))
            report['cases']['copiedClientRejected']=code==77 and value=={'pathRejected':True}
            copied=task/'copied-server';shutil.copy2(server,copied)
            code,value=once(copied)
            report['cases']['copiedServerRejected']=code==77 and value=={'pathRejected':True}
            lock.rename(root/'original.lock');lock.write_bytes(b'');lock.chmod(0o600)
            report['cases']['replacedLockRejected']=call(endpoint).get('ok') is False
            lock.unlink();(root/'original.lock').rename(lock)
            code,value=once(enroll,['delete']);created=False
            report['cases']['ownedItemRemoved']=code==0 and value.get('removed') is True
            report['cases']['missingItemNoReset']=call(endpoint).get('ok') is False
            code,value=once(server,['create'])
            report['cases']['missingItemCannotReenroll']=code==77 and value=={'enrollmentRejected':True}
            code,value=once(server)
            report['cases']['missingItemPreventsStartup']=code==78 and value.get('rootUnavailable') is True
            stop(p)
            report['cases']['fixturesExited']=all(subprocess.run(['launchctl','print',p.target],capture_output=True).returncode!=0 for p in processes)
            for binary,identifier in [(server,serverID),(client,clientID),(foreign,'org.keylane.tests.runtime-m0.foreign-server')]:
                m0.run(['codesign','--verify','--strict','-R='+requirement(identifier),str(binary)],capture_output=True)
            m0.verify_signature(sandbox_app,identity,plistlib.loads((broker.FIXTURE/'helper.entitlements').read_bytes()))
            m0.verify_signature(peer_app,identity,plistlib.loads((broker.FIXTURE/'helper.entitlements').read_bytes()))
            report['signaturesVerifiedBeforeAndAfter']=True
            report['gate'],report['failures']=verdict(report['cases'])
        finally:
            for p in processes:stop(p)
            if provision_attempted:
                code,value=once(enroll,['delete'])
                if code!=0 or value.get('removed') is not True:raise RuntimeError('Synthetic Keychain cleanup failed')
                (task/'cleanup-pending.json').unlink()
    report['temporaryArtifactsRemoved']=True
    args.report.parent.mkdir(parents=True,exist_ok=True)
    with args.report.open('x') as output:json.dump(report,output,indent=2)
    print(json.dumps({'gate':report['gate'],'failures':report['failures'],'report':str(args.report)}))
    return 2 if report['gate']=='blocked' else 3


if __name__=='__main__':raise SystemExit(main())
