"""Fixed macOS build-tool packaging. No npm, scripts, source compilation or keys."""
import base64
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


def package_builder(app, helper_binary, identity, host_identifier='org.keylane.launcher', archive=None, team=None):
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
        subprocess.run(['codesign','--force','--sign',identity,'--options','runtime','--timestamp=none',
                        '--identifier','org.keylane.extension-compiler','--entitlements',str(inherit),str(tool)],check=True,capture_output=True)
        if team is None:team = team_for(tool)
        parent = scratch/'parent.plist';parent.write_bytes(plistlib.dumps({'signing-identifier':host_identifier,'team-identifier':team}))
        subprocess.run(['codesign','--validate-constraint',str(parent)],check=True,capture_output=True)
        subprocess.run(['codesign','--force','--sign',identity,'--options','runtime','--timestamp=none',
                        '--entitlements',str(sandbox),'--launch-constraint-parent',str(parent),str(target)],check=True,capture_output=True)
    recipe = dict(schema=1,policy='restricted-jsc-build-v1',target='darwin-arm64',compilerVersion='0.25.5',
                  compilerSHA256=hashlib.sha256(tool.read_bytes()).hexdigest(),helperSHA256=hashlib.sha256(helper.read_bytes()).hexdigest())
    config = app/'Contents/Resources/ExtensionBuild.json';config.parent.mkdir(exist_ok=True)
    config.write_text(json.dumps(dict(schema=1,mode='build-only',recipe=recipe),sort_keys=True)+'\n')


def verify_builder(app):
    config = app/'Contents/Resources/ExtensionBuild.json'
    if not config.exists():raise ValueError('Missing fixed build profile')
    profile = json.loads(config.read_text())
    recipe = profile['recipe']
    if profile['schema'] != 1 or profile['mode'] != 'build-only' or recipe['schema'] != 1 or recipe['policy'] != 'restricted-jsc-build-v1' or recipe['target'] != 'darwin-arm64' or recipe['compilerVersion'] != '0.25.5':
        raise ValueError('Unexpected build-only profile')
    team = team_for(app)
    hardened(app)
    for relative,identifier,rights,key in [
        (HELPER,'org.keylane.extension-build',{'com.apple.security.app-sandbox':True},'helperSHA256'),
        (HELPER+'/Contents/MacOS/esbuild','org.keylane.extension-compiler',{'com.apple.security.app-sandbox':True,'com.apple.security.inherit':True},'compilerSHA256')]:
        path = app/relative
        hardened(path)
        requirement = 'anchor apple generic and identifier "'+identifier+'" and certificate leaf[subject.OU] = "'+team+'"'
        subprocess.run(['codesign','--verify','--strict','-R='+requirement,str(path)],check=True,capture_output=True)
        raw = subprocess.check_output(['codesign','-d','--entitlements','-','--xml',str(path)],stderr=subprocess.DEVNULL)
        if plistlib.loads(raw) != rights:raise ValueError('Unexpected build helper rights')
        binary = path/'Contents/MacOS/keylane-extension-build' if key == 'helperSHA256' else path
        if hashlib.sha256(binary.read_bytes()).hexdigest() != recipe[key]:raise ValueError('Build tool profile digest mismatch')
    license = app/HELPER/'Contents/Resources/esbuild-LICENSE.txt'
    if license.read_bytes() != (ROOT/'Resources/ExtensionBuild-esbuild-LICENSE.txt').read_bytes():raise ValueError('Incorrect compiler license')
    if (app/HELPER/'Contents/Resources/Go-LICENSE.txt').read_bytes() != (ROOT/'Resources/ExtensionBuild-Go-LICENSE.txt').read_bytes():raise ValueError('Incorrect Go license')
    return {HELPER+'/'+p for p in ['Contents/MacOS/keylane-extension-build','Contents/MacOS/esbuild',
            'Contents/Info.plist','Contents/Resources/esbuild-LICENSE.txt','Contents/Resources/Go-LICENSE.txt','Contents/_CodeSignature/CodeResources']} | {'Contents/Resources/ExtensionBuild.json'}
