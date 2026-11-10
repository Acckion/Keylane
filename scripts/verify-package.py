#!/usr/bin/env python3
"""Verify the distributable, not a developer's installed app."""
import platform
import plistlib
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from versioning import ROOT, load_version

version = load_version()
if len(sys.argv) > 2:
    raise SystemExit('usage: verify-package.py [one ZIP path]')
archive = Path(sys.argv[1]) if len(sys.argv) == 2 else ROOT / 'dist' / f"Keylane-{version['version']}-macos-{platform.machine()}.zip"
with zipfile.ZipFile(archive) as bundle, tempfile.TemporaryDirectory(prefix='keylane-package-') as temporary:
    names = bundle.namelist()
    expected = {'Keylane.app/Contents/MacOS/Keylane', 'Keylane.app/Contents/Info.plist', 'Keylane.app/Contents/Resources/LICENSE', 'Keylane.app/Contents/_CodeSignature/CodeResources'}
    if set(names) != expected or len(names) != len(expected):
        raise SystemExit('unexpected/missing package contents: ' + repr(names))
    info = plistlib.loads(bundle.read('Keylane.app/Contents/Info.plist'))
    if info['CFBundleShortVersionString'] != version['version'] or info['CFBundleVersion'] != str(version['build']):
        raise SystemExit('package version does not match version.json')
    if info['CFBundleIdentifier'] != 'org.keylane.launcher' or info['LSMinimumSystemVersion'] != '26.0':
        raise SystemExit('unexpected bundle identity or deployment target')
    if bundle.read('Keylane.app/Contents/Resources/LICENSE') != (ROOT / 'LICENSE').read_bytes():
        raise SystemExit('missing or different license')
    if not bundle.getinfo('Keylane.app/Contents/MacOS/Keylane').external_attr >> 16 & 0o111:
        raise SystemExit('ZIP executable permission missing')
    bundle.extractall(temporary)
    app = Path(temporary) / 'Keylane.app'
    binary = app / 'Contents/MacOS/Keylane'
    binary.chmod(0o755)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    architectures = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip()
    if architectures not in ('arm64', 'x86_64') or archive.name != f"Keylane-{version['version']}-macos-{architectures}.zip":
        raise SystemExit('filename/architecture mismatch: ' + architectures)
print('Package metadata, license, file inventory, architecture and signature: OK')
