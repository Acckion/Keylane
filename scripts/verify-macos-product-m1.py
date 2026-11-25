#!/usr/bin/env python3
"""Signed real M1 composition; exact synthetic Keychain slots and temporary files.

The optional official UUID check installs only in the temporary signed profile.
Clipboard effects are captured in the test host.
Retains the original signed recovery application if owned cleanup fails.
"""
import argparse
import contextlib
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT/'scripts'))
from extension_builder import LEGACY_PREVIEW_STORAGE, package_builder, verify_builder, provisioned_rights, package_runtime
spec=importlib.util.spec_from_file_location('m0',ROOT/'scripts/verify-macos-runtime-m0.py')
m0=importlib.util.module_from_spec(spec);spec.loader.exec_module(m0)
spec=importlib.util.spec_from_file_location('broker',ROOT/'scripts/verify-macos-broker-m0.py')
broker=importlib.util.module_from_spec(spec);spec.loader.exec_module(broker)
CASES={'enrolled','approvalReplayRejected','realBuildAndInstall','oldActiveDuringStaging','atomicReplacement',
       'preferencesPreserved','executionStillClosed','restartPersistent','foreignReadDenied','copiedHostRejected',
       'uncommittedPublicationDiscarded','committedPublicationRecovered','registryRollbackRejected',
       'missingHeadNoReset','missingProfileNoReset','cachedSignerRevoked','wrongParentRejected',
       'realCompilerCancelled','oldPreservedAfterCancellation','oldPreservedAfterCompilerFailure',
       'crossProcessCASOneWinner','crossProcessCASRecoverable','tamperedToolchainRejected','fixturesExited','crossProcessBuildLock','productHostRightsVerified',
       'foreignProfileRejected','foreignLegacyReadableByHost','foreignProtectedCreateDenied','foreignProtectedUpdateDenied','unprovisionedHostRejected'}


def choose_provision(path, identifier, identity):
    if path:return path,provisioned_rights(path,identifier,identity)
    candidates=[]
    for directory in [Path.home()/'Library/Developer/Xcode/UserData/Provisioning Profiles',Path.home()/'Library/MobileDevice/Provisioning Profiles']:
        for path in directory.glob('*provisionprofile'):
            try:candidates.append((path,provisioned_rights(path,identifier,identity)))
            except (ValueError,subprocess.CalledProcessError):continue
    if len(candidates)!=1:raise ValueError('Supply one existing profile authorizing the synthetic host; no provisioning changes or fallback')
    return candidates[0]


def verdict(cases):
    if any(type(cases.get(key)) is not bool for key in CASES):raise ValueError('Missing M1 composition observation')
    failures=sorted(key for key in CASES if not cases[key])
    return ('blocked',failures) if failures else ('passed',[])


@contextlib.contextmanager
def task_directory():
    task=Path(tempfile.mkdtemp(prefix='keylane-m1-product-',dir='/private/tmp'))
    try:yield task
    finally:
        if (task/'cleanup.json').exists():raise RuntimeError('Cleanup pending; signed recovery application retained at '+str(task))
        shutil.rmtree(task)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--helper',type=Path,required=True);p.add_argument('--compiler-archive',type=Path,required=True)
    p.add_argument('--core-products',type=Path,help='fresh SwiftPM Debug products for this checkout')
    p.add_argument('--package-name',default=re.sub(r'\W','_',ROOT.name.lower()))
    p.add_argument('--provisioning-profile',type=Path,help='Existing macOS profile authorizing only the signed synthetic host')
    mode = p.add_mutually_exclusive_group()
    mode.add_argument('--runtime-helper',type=Path,help='Run the signed M2 composition only')
    mode.add_argument('--origin-only',action='store_true',help='Only audit legacy foreign-origin adoption; never grants M1 acceptance')
    p.add_argument('--official-lorem', action='store_true', help='Run reviewed Lorem Ipsum commands only')
    p.add_argument('--official-batch', action='store_true', help='Also run the reviewed Silent Mention command')
    p.add_argument('--official-uuid', action='store_true',
                   help='Fetch and execute the pinned official UUID Generator command in a temporary profile')
    p.add_argument('--legacy-preview', action='store_true', help='Exercise the runtime using isolated login Keychain slots')
    p.add_argument('--batch-03-view-build', type=Path, metavar='REACT_ARCHIVE_DIRECTORY')
    p.add_argument('--batch-02-file-build', action='store_true')
    p.add_argument('--batch-02-protected-vault', action='store_true')
    p.add_argument('--report',type=Path,required=True);args=p.parse_args()
    if args.batch_02_protected_vault and (not args.runtime_helper or args.legacy_preview):
        p.error('--batch-02-protected-vault requires protected runtime mode')
    if args.batch_03_view_build and not args.runtime_helper:
        p.error('--batch-03-view-build requires --runtime-helper')
    if args.batch_02_file_build and not args.runtime_helper:
        p.error('--batch-02-file-build requires --runtime-helper')
    if args.legacy_preview and (not args.runtime_helper or args.provisioning_profile):
        p.error('--legacy-preview requires --runtime-helper and no provisioning profile')
    if args.official_batch and not args.official_uuid:
        p.error('--official-batch requires --official-uuid')
    if (args.official_uuid or args.official_lorem) and not args.runtime_helper:
        p.error('--official-uuid requires --runtime-helper')
    if args.report.exists():raise SystemExit('Refusing report overwrite')
    identity=m0.resolve_identity()
    report=dict(schema=1,fixtureOnly=True,installed=False,phase='M1',cases={},productionRuntimeReady=False,publicExtensionsVerified=False,
                protectedStorage=LEGACY_PREVIEW_STORAGE if args.legacy_preview else 'data-protection-keychain-v2',
                provisionedFixtureOnly=not args.legacy_preview)
    with task_directory() as task:
        if args.batch_03_view_build:
            for name in ['react', 'react-reconciler', 'scheduler']:
                archive = args.batch_03_view_build/(name + '.tgz')
                if archive.stat().st_size > 2 * 1024 * 1024:
                    raise ValueError('React archive too large')
                shutil.copyfile(archive, task/archive.name)
            shutil.copyfile(ROOT/'Tests/ExtensionPrototype/MacOSRuntimeM2/Batch03NativeView.tsx', task/'batch-03-view.tsx')
        app=task/'Host.app';host=app/'Contents/MacOS/host';host.parent.mkdir(parents=True)
        identifier='org.keylane.tests.runtime-m1.product-host'
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=identifier,CFBundleExecutable='host',CFBundlePackageType='APPL')))
        sources=sorted((ROOT/'Sources/KeylaneCore').glob('*.swift'))
        package_name='Keylane';extra=['-whole-module-optimization']
        if args.core_products:
            sources=[];package_name=args.package_name
            extra=['-DM1_LINKED_CORE','-I',str(args.core_products),str(args.core_products/'KeylaneCore.o')]
        compiled=subprocess.run(['swiftc','-swift-version','5','-package-name',package_name,'-parse-as-library','-target','arm64-apple-macos26.0',
                '-O',*extra,*map(str,sources),str(ROOT/'Tests/ExtensionPrototype/MacOSRuntimeM1/ProductHost.swift'),'-o',str(host)],capture_output=True,text=True,timeout=180)
        if compiled.returncode:raise RuntimeError('First-party host compile failed: '+compiled.stderr[-5000:])
        package_builder(app,args.helper,identity,host_identifier=identifier,archive=args.compiler_archive)
        ordinary_rights=plistlib.loads((ROOT/'Resources/Keylane.entitlements').read_bytes())
        product_rights=dict(ordinary_rights)
        if not args.legacy_preview:
            provision,protected_rights=choose_provision(args.provisioning_profile,identifier,identity)
            shutil.copyfile(provision,app/'Contents/embedded.provisionprofile')
            product_rights.update(protected_rights)
        def sign(target,role,entitlements=None):
            entitlements=entitlements or {}
            rights=task/(role+'.plist');rights.write_bytes(plistlib.dumps(entitlements))
            m0.run(['codesign','--force','--sign',identity,'--identifier',role,'--options','runtime','--timestamp=none','--entitlements',str(rights),str(target)],capture_output=True)
            m0.verify_signature(target,identity,entitlements)
        if args.runtime_helper:
            runtime = package_runtime(app, args.runtime_helper, identity, host_identifier=identifier, legacy_preview=args.legacy_preview)
            runner = runtime/'Contents/MacOS/keylane-extension-run'
            runtime_rights = {'com.apple.security.app-sandbox':True}
            m0.verify_signature(runtime,identity,runtime_rights)
        sign(app,identifier,product_rights)
        verify_builder(app)
        def call(mode,binary=host):
            result=subprocess.run([str(binary),mode,str(task)],capture_output=True,text=True,timeout=120)
            if result.returncode!=0:raise RuntimeError('First-party native M1 mode failed: '+mode+'; exit='+str(result.returncode)+'; '+result.stdout[:160]+'; '+result.stderr[:600])
            values=json.loads(result.stdout);report['cases'].update(values)
        if args.runtime_helper:
            try:
                call('runtime-setup')
                if args.batch_02_protected_vault:
                    call('batch-02-protected-vault')
                if args.batch_02_file_build:
                    call('batch-02-file-build')
                if args.batch_03_view_build:
                    call('batch-03-view-build')
                call('runtime-service')
                call('runtime-restart')
                call('runtime-after-uninstall')
                if args.official_uuid:
                    call('official-uuid-run')
                    call('official-uuid-restart')
                if args.official_batch:
                    call('official-silent-mention')
                    call('official-silent-mention-restart')
                if args.official_batch or args.official_lorem:
                    call('official-lorem-markdown')
                    call('official-lorem-markdown-restart')
                m0.verify_signature(runtime,identity,runtime_rights)
                m0.verify_signature(app,identity,product_rights)
                report['signaturesVerifiedBeforeAndAfter'] = True
                report['cases']['fixturesExited'] = not broker.helper_pids(runner)
            finally:
                if (task/'cleanup.json').exists():
                    call('cleanup')
            report['temporaryArtifactsRemoved'] = True
            report['phase'] = 'M2-signed-service-dispatch'
            required = {'approvalReplayRejected', 'enrolled', 'competingServiceDenied',
                        'signedProfileDispatch', 'staleLauncherCommandDenied', 'fixturesExited', 'cleaned',
                        'unsupportedCommandDeniedBeforeInstall', 'restartDispatch', 'disabledCommandDenied',
                        'uninstallRecorded', 'uninstallPersistsAfterRestart'}
            if args.batch_02_protected_vault:
                required |= {'protectedCredentialKeyReopened', 'credentialCiphertextBoundToInstallation'}
            if args.batch_02_file_build:
                required.add('signedVirtualFileImportsBuilt')
            if args.batch_03_view_build:
                required |= {'signedReactViewBuilt', 'builtReactPreservesMITNotice'}
            if args.official_uuid:
                official_cases = {'officialUUIDInstalledAndRan', 'officialUUIDMissingArgumentRejected',
                                  'officialUUIDRestartAndUninstall'}
                required |= official_cases
            if args.official_batch:
                required |= {'officialSilentMentionInstalledAndRan', 'officialSilentMentionRestartAndUninstall'}
            if args.official_batch or args.official_lorem:
                required |= {'officialLoremMarkdownInstalledAndRan', 'officialLoremMarkdownRestartAndUninstall'}
            report['publicExtensionsVerified'] = (args.official_uuid or args.official_lorem) and all(
                report['cases'].get(key) is True for key in required if key.startswith('official'))
            report['gate'] = 'incomplete' if all(report['cases'].get(key) is True for key in required) else 'blocked'
            with args.report.open('x') as output:
                json.dump(report,output,indent=2)
            print(json.dumps({'gate':report['gate'],'cases':report['cases']}))
            return 0 if report['gate']=='incomplete' else 2
        if args.origin_only:
            try:
                foreign=task/'Foreign.app';shutil.copytree(app,foreign);sign(foreign,'org.keylane.tests.runtime-m1.foreign')
                call('forge-legacy-profile',foreign/'Contents/MacOS/host');call('adopt-forged-profile')
                required=['foreignProfileRejected','foreignLegacyReadableByHost','foreignProtectedCreateDenied','foreignProtectedUpdateDenied']
                report['failures']=[key for key in required if report['cases'].get(key)is not True]
                report['gate']='blocked'if report['failures']else'incomplete'
                report['signaturesVerifiedBeforeAndAfter']=True
            finally:
                if (task/'cleanup.json').exists():call('cleanup')
            report['temporaryArtifactsRemoved']=True
            with args.report.open('x')as f:json.dump(report,f,indent=2)
            print(json.dumps({'gate':report['gate'],'cases':report['cases']}))
            return 3 if report['gate']=='incomplete'else 2
        try:
            call('setup');call('build');call('restart')
            held=subprocess.Popen([str(host),'hold-build-lock',str(task)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                if json.loads(held.stdout.readline()).get('lockHeld') is not True:raise RuntimeError('Native build lock control failed')
                call('lock-busy')
            finally:
                (task/'release-lock').write_text('first-party release')
                _,err=held.communicate(timeout=20)
                if held.returncode!=0:raise RuntimeError('Native build lock cleanup failed: '+err[:500])
            helper=app/'Contents/Helpers/KeylaneExtensionBuild.app/Contents/MacOS/keylane-extension-build'
            tool=helper.parent/'esbuild'
            cancel=subprocess.Popen([str(host),'cancel',str(task)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            observed=False
            try:
                end=time.monotonic()+15
                while time.monotonic()<end:
                    if broker.helper_pids(tool):observed=True;break
                    if cancel.poll()is not None:break
                    time.sleep(0.005)
                (task/'cancel-now').write_text('first-party cancellation')
                out,err=cancel.communicate(timeout=40)
                if cancel.returncode!=0:raise RuntimeError('Real compiler cancellation failed: '+err[:600])
                report['cases'].update(json.loads(out))
                report['cases']['realCompilerCancelled']=observed and report['cases']['realCompilerCancelled']
            finally:
                if cancel.poll()is None:cancel.kill()
                cancel.wait(timeout=5);broker.confirm_helper_exit(tool);broker.confirm_helper_exit(helper)
            call('build-failure')
            original=task/'original-helper';helper.rename(original)
            try:
                body=bytearray(original.read_bytes());body[-16]^=1;helper.write_bytes(body);helper.chmod(0o755)
                call('tamper')
            finally:
                helper.unlink();original.rename(helper)
            call('restart')
            copy=task/'Copy.app';shutil.copytree(app,copy);call('copy',copy/'Contents/MacOS/host')
            plain=task/'Plain.app';shutil.copytree(app,plain);(plain/'Contents/embedded.provisionprofile').unlink()
            sign(plain,identifier,ordinary_rights);call('no-provision',plain/'Contents/MacOS/host')
            foreign=task/'Foreign.app';shutil.copytree(app,foreign);sign(foreign,'org.keylane.tests.runtime-m1.foreign')
            call('foreign',foreign/'Contents/MacOS/host')
            call('forge-legacy-profile',foreign/'Contents/MacOS/host');call('adopt-forged-profile')
            direct=subprocess.run([str(helper)],input=b'{}',capture_output=True,timeout=8)
            report['cases']['wrongParentRejected']=direct.returncode<0 and not direct.stdout
            call('recovery')
            racers=[subprocess.Popen([str(host),'cas',str(task)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)for _ in range(2)]
            winners=[]
            for racer in racers:
                out,err=racer.communicate(timeout=30)
                if racer.returncode!=0:raise RuntimeError('Native CAS process failed: '+err[:500])
                winners.append(json.loads(out)['casAdvanced'])
            report['cases']['crossProcessCASOneWinner']=sorted(winners)==[False,True]
            call('cas-recover');call('missing')
            report['cases']['fixturesExited']=not broker.helper_pids(tool)and not broker.helper_pids(helper)
            m0.verify_signature(app,identity,product_rights)
            report['cases']['productHostRightsVerified']=True
            verify_builder(app)
            report['signaturesVerifiedBeforeAndAfter']=True
            report['gate'],report['failures']=verdict(report['cases'])
        finally:
            if (task/'cleanup.json').exists():call('cleanup')
    report['temporaryArtifactsRemoved']=True
    args.report.parent.mkdir(parents=True,exist_ok=True)
    with args.report.open('x')as f:json.dump(report,f,indent=2)
    print(json.dumps({'gate':report['gate'],'failures':report['failures'],'report':str(args.report)}))
    return 0 if report['gate']=='passed' else 2


if __name__=='__main__':raise SystemExit(main())
