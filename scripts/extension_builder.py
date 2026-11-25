"""Fixed macOS build-tool packaging. No npm, scripts, source compilation or keys."""
import base64
import datetime
import fnmatch
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
HELPER = 'Contents/Helpers/KeylaneExtensionBuild.app'
PROTECTED_STORAGE = 'data-protection-keychain-v2'
LEGACY_PREVIEW_STORAGE = 'legacy-login-keychain-preview-v1'


def provisioned_rights(path, identifier, identity, now=None):
    """Read public signing authorization only; never print device/cert contents."""
    result=subprocess.run(['security','cms','-D','-i',str(path)],check=True,capture_output=True)
    profile=plistlib.loads(result.stdout); rights=profile.get('Entitlements',{})
    team=rights.get('com.apple.developer.team-identifier','')
    application=team+'.'+identifier
    now=now or datetime.datetime.now(datetime.timezone.utc)
    expiry=profile.get('ExpirationDate',datetime.datetime.min)
    if expiry.tzinfo is None:expiry=expiry.replace(tzinfo=datetime.timezone.utc)
    if ('OSX' not in profile.get('Platform',[]) or expiry<=now or not team or
        not any(hashlib.sha1(c).hexdigest().lower()==identity.lower() for c in profile.get('DeveloperCertificates',[])) or
        not fnmatch.fnmatchcase(application,rights.get('com.apple.application-identifier','')) or
        not any(fnmatch.fnmatchcase(application,group) for group in rights.get('keychain-access-groups',[]))):
        raise ValueError('Provisioning profile does not authorize the requested host')
    return {'com.apple.application-identifier':application,'com.apple.developer.team-identifier':team,
            'keychain-access-groups':[application]}


def package_runtime(app, runner_binary, identity, host_identifier='org.keylane.launcher', distribution=False, legacy_preview=False):
    """Add an explicitly opted-in runner before the outer app is signed."""
    if distribution and legacy_preview:
        raise ValueError('Legacy runtime preview cannot be used for Developer ID distribution')
    if identity == '-' or not runner_binary.is_file():
        raise ValueError('The ARM64 runtime needs the native runner and a real signing identity')
    config = app/'Contents/Resources/ExtensionBuild.json'
    profile = json.loads(config.read_text())
    if profile.get('mode') != 'build-only' or 'runHelperSHA256' in profile:
        raise ValueError('Expected an unmodified build composition')
    runtime = app/'Contents/Helpers/KeylaneExtensionRun.app'
    runner = runtime/'Contents/MacOS/keylane-extension-run'
    runner.parent.mkdir(parents=True)
    shutil.copyfile(runner_binary, runner)
    runner.chmod(0o755)
    (runtime/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier='org.keylane.extension-run', CFBundleExecutable=runner.name, CFBundlePackageType='APPL')))
    compiler = app/HELPER/'Contents/MacOS/esbuild'
    with tempfile.TemporaryDirectory(prefix='keylane-runtime-sign-') as directory:
        rights = Path(directory)/'sandbox.plist'
        parent = Path(directory)/'parent.plist'
        rights.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True}))
        parent.write_bytes(plistlib.dumps({'signing-identifier':host_identifier,'team-identifier':team_for(compiler)}))
        subprocess.run(['codesign','--validate-constraint',str(parent)],check=True,capture_output=True)
        subprocess.run(['codesign','--force','--sign',identity,'--options','runtime',
                        '--timestamp' if distribution else '--timestamp=none',
                        '--entitlements',str(rights),'--launch-constraint-parent',str(parent),str(runtime)],
                       check=True,capture_output=True)
    profile.update(mode='restricted-no-view',runHelperSHA256=hashlib.sha256(runner.read_bytes()).hexdigest())
    if legacy_preview:
        profile['storage'] = LEGACY_PREVIEW_STORAGE
    config.write_text(json.dumps(profile,sort_keys=True)+'\n')
    return runtime


def archive_bytes(path=None):
    lock = json.loads((ROOT/'Resources/ExtensionBuildToolchain.json').read_text())
    if path:
        with Path(path).open('rb') as source:body = source.read(16 * 1024 * 1024 + 1)
    else:
        with urllib.request.urlopen(lock['url'],timeout=30) as source:body = source.read(16 * 1024 * 1024 + 1)
    if len(body) > 16 * 1024 * 1024 or 'sha512-' + base64.b64encode(hashlib.sha512(body).digest()).decode() != lock['integrity']:
        raise ValueError('Fixed build compiler integrity mismatch')
    return body


def team_for(binary):
    detail = subprocess.check_output(['codesign','-dv','--verbose=4',str(binary)],stderr=subprocess.STDOUT,text=True)
    match = re.search(r'^TeamIdentifier=([A-Z0-9]+)$',detail,re.M)
    if not match:raise ValueError('Real signing team required for extension builder')
    return match.group(1)


def hardened(binary):
    detail=subprocess.check_output(['codesign','-dv','--verbose=4',str(binary)],stderr=subprocess.STDOUT,text=True)
    flags=re.search(r'flags=0x([0-9a-fA-F]+)',detail)
    if not flags or int(flags.group(1),16)&0x10000==0:raise ValueError('Build composition requires Hardened Runtime')


def builder_enabled(architecture, identity, distribution):
    if distribution and identity == '-':raise ValueError('Distribution requires a real signing identity')
    return architecture == 'arm64' and identity != '-'


def package_builder(app, helper_binary, identity, host_identifier='org.keylane.launcher', archive=None, team=None, distribution=False):
    if identity == '-':raise ValueError('Extension builder requires a real signing identity')
    if not helper_binary.is_file():raise ValueError('Missing fixed native build helper product')
    target = app/HELPER
    helper = target/'Contents/MacOS/keylane-extension-build'
    helper.parent.mkdir(parents=True)
    shutil.copyfile(helper_binary,helper);helper.chmod(0o755)
    tool = helper.parent/'esbuild'
    with tarfile.open(fileobj=io.BytesIO(archive_bytes(archive))) as package:
        member = package.getmember('package/bin/esbuild')
        if not member.isfile() or member.size > 16 * 1024 * 1024:raise ValueError('Invalid compiler member')
        tool.write_bytes(package.extractfile(member).read());tool.chmod(0o755)
    (target/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='org.keylane.extension-build',
        CFBundleExecutable='keylane-extension-build',CFBundlePackageType='APPL',LSMinimumSystemVersion='26.0',LSUIElement=True)))
    resources = target/'Contents/Resources';resources.mkdir()
    shutil.copyfile(ROOT/'Resources/ExtensionBuild-esbuild-LICENSE.txt',resources/'esbuild-LICENSE.txt')
    shutil.copyfile(ROOT/'Resources/ExtensionBuild-Go-LICENSE.txt',resources/'Go-LICENSE.txt')
    with tempfile.TemporaryDirectory(prefix='keylane-build-sign-') as temporary:
        scratch = Path(temporary)
        inherit = scratch/'inherit.plist';inherit.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.inherit':True}))
        sandbox = scratch/'sandbox.plist';sandbox.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True}))
        timestamp = '--timestamp' if distribution else '--timestamp=none'
        subprocess.run(['codesign','--force','--sign',identity,'--options','runtime',timestamp,
                        '--identifier','org.keylane.extension-compiler','--entitlements',str(inherit),str(tool)],check=True,capture_output=True)
        if team is None:team = team_for(tool)
        parent = scratch/'parent.plist';parent.write_bytes(plistlib.dumps({'signing-identifier':host_identifier,'team-identifier':team}))
        subprocess.run(['codesign','--validate-constraint',str(parent)],check=True,capture_output=True)
        subprocess.run(['codesign','--force','--sign',identity,'--options','runtime',timestamp,
                        '--entitlements',str(sandbox),'--launch-constraint-parent',str(parent),str(target)],check=True,capture_output=True)
    recipe = dict(schema=1,policy='restricted-jsc-build-v1',target='darwin-arm64',compilerVersion='0.25.5',
                  compilerSHA256=hashlib.sha256(tool.read_bytes()).hexdigest(),helperSHA256=hashlib.sha256(helper.read_bytes()).hexdigest())
    config = app/'Contents/Resources/ExtensionBuild.json';config.parent.mkdir(exist_ok=True)
    config.write_text(json.dumps(dict(schema=2,mode='build-only',storage=PROTECTED_STORAGE,recipe=recipe),sort_keys=True)+'\n')


def verify_build_composition(app, architecture, distribution=False):
    if architecture != 'arm64':return set()
    detail = subprocess.check_output(['codesign','-dv','--verbose=4',str(app)],stderr=subprocess.STDOUT,text=True)
    if 'Signature=adhoc' in detail.splitlines():
        if distribution:raise ValueError('Ad-hoc signature is not a distribution composition')
        if (app/HELPER).exists() or (app/'Contents/Resources/ExtensionBuild.json').exists():
            raise ValueError('Certificate-free isolated package must omit the entire build composition')
        return set()
    return verify_builder(app, distribution=distribution)


def require_timestamp(binary):
    detail = subprocess.check_output(['codesign','-dv','--verbose=4',str(binary)],stderr=subprocess.STDOUT,text=True)
    if not re.search(r'^Timestamp=.+$',detail,re.M):raise ValueError('Distribution build tool lacks secure timestamp')


def verify_builder(app, distribution=False):
    config = app/'Contents/Resources/ExtensionBuild.json'
    if not config.exists():raise ValueError('Missing fixed build profile')
    profile = json.loads(config.read_text())
    recipe = profile['recipe']
    if profile['schema'] != 2 or profile['mode'] not in ('build-only','restricted-no-view') or recipe['schema'] != 1 or recipe['policy'] != 'restricted-jsc-build-v1' or recipe['target'] != 'darwin-arm64' or recipe['compilerVersion'] != '0.25.5':
        raise ValueError('Unexpected build-only profile')
    legacy_preview = profile.get('storage') == LEGACY_PREVIEW_STORAGE
    if legacy_preview:
        if distribution or profile['mode'] != 'restricted-no-view':
            raise ValueError('Unexpected legacy runtime preview')
    elif profile.get('storage') != PROTECTED_STORAGE:
        raise ValueError('Unknown build profile storage')
    team = team_for(app)
    hardened(app)
    for relative,identifier,rights,key in [
        (HELPER,'org.keylane.extension-build',{'com.apple.security.app-sandbox':True},'helperSHA256'),
        (HELPER+'/Contents/MacOS/esbuild','org.keylane.extension-compiler',{'com.apple.security.app-sandbox':True,'com.apple.security.inherit':True},'compilerSHA256')]:
        path = app/relative
        hardened(path)
        if distribution:require_timestamp(path)
        requirement = 'anchor apple generic and identifier "'+identifier+'" and certificate leaf[subject.OU] = "'+team+'"'
        subprocess.run(['codesign','--verify','--strict','-R='+requirement,str(path)],check=True,capture_output=True)
        raw = subprocess.check_output(['codesign','-d','--entitlements','-','--xml',str(path)],stderr=subprocess.DEVNULL)
        if plistlib.loads(raw) != rights:raise ValueError('Unexpected build helper rights')
        binary = path/'Contents/MacOS/keylane-extension-build' if key == 'helperSHA256' else path
        if hashlib.sha256(binary.read_bytes()).hexdigest() != recipe[key]:raise ValueError('Build tool profile digest mismatch')
    runtime_files = set()
    if profile['mode'] == 'restricted-no-view':
        runtime = 'Contents/Helpers/KeylaneExtensionRun.app'
        path = app/runtime
        hardened(path)
        if distribution:require_timestamp(path)
        requirement = 'anchor apple generic and identifier "org.keylane.extension-run" and certificate leaf[subject.OU] = "'+team+'"'
        subprocess.run(['codesign','--verify','--strict','-R='+requirement,str(path)],check=True,capture_output=True)
        rights = subprocess.check_output(['codesign','-d','--entitlements','-','--xml',str(path)],stderr=subprocess.DEVNULL)
        if plistlib.loads(rights) != {'com.apple.security.app-sandbox':True}:
            raise ValueError('Unexpected runtime helper entitlements')
        if hashlib.sha256((path/'Contents/MacOS/keylane-extension-run').read_bytes()).hexdigest() != profile.get('runHelperSHA256'):
            raise ValueError('Runtime profile digest mismatch')
        host_info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
        host_rights = plistlib.loads(subprocess.check_output(
            ['codesign','-d','--entitlements','-','--xml',str(app)],stderr=subprocess.DEVNULL))
        provision_path = app/'Contents/embedded.provisionprofile'
        runtime_files = {runtime+'/'+name for name in ['Contents/MacOS/keylane-extension-run',
                         'Contents/Info.plist','Contents/_CodeSignature/CodeResources']}
        if legacy_preview:
            if provision_path.exists() or {'keychain-access-groups', 'com.apple.application-identifier'} & host_rights.keys():
                raise ValueError('Legacy runtime preview must omit provisioned host rights')
        else:
            with tempfile.TemporaryDirectory(prefix='keylane-runtime-verify-') as directory:
                prefix = Path(directory)/'certificate'
                subprocess.run(['codesign','-d','--extract-certificates='+str(prefix),str(app)],check=True,capture_output=True)
                fingerprint = hashlib.sha1((Path(directory)/'certificate0').read_bytes()).hexdigest()
            expected = provisioned_rights(provision_path, host_info['CFBundleIdentifier'], fingerprint)
            if expected['com.apple.application-identifier'] != team + '.' + host_info['CFBundleIdentifier'] or any(
                    host_rights.get(key) != value for key,value in expected.items()):
                raise ValueError('Missing explicit runtime host entitlements')
            runtime_files.add('Contents/embedded.provisionprofile')
    elif 'runHelperSHA256' in profile:
        raise ValueError('Build-only manifest must omit runtime binding')
    license = app/HELPER/'Contents/Resources/esbuild-LICENSE.txt'
    if license.read_bytes() != (ROOT/'Resources/ExtensionBuild-esbuild-LICENSE.txt').read_bytes():raise ValueError('Incorrect compiler license')
    if (app/HELPER/'Contents/Resources/Go-LICENSE.txt').read_bytes() != (ROOT/'Resources/ExtensionBuild-Go-LICENSE.txt').read_bytes():raise ValueError('Incorrect Go license')
    return {HELPER+'/'+p for p in ['Contents/MacOS/keylane-extension-build','Contents/MacOS/esbuild',
            'Contents/Info.plist','Contents/Resources/esbuild-LICENSE.txt','Contents/Resources/Go-LICENSE.txt','Contents/_CodeSignature/CodeResources']} | {'Contents/Resources/ExtensionBuild.json'} | runtime_files
