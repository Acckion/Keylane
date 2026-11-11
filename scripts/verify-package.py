#!/usr/bin/env python3
"""Mount and verify the exact disk image intended for distribution."""
import argparse
import os
import platform
import plistlib
import subprocess
import tempfile
from pathlib import Path

from versioning import ROOT, load_version

APPLE_EVENTS_ENTITLEMENT = "com.apple.security.automation.apple-events"
DEVELOPER_ID_REQUIREMENT = '-R=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'


def verify_app(app, image, version, distribution):
    expected = {
        'Contents/MacOS/Keylane',
        'Contents/Info.plist',
        'Contents/Resources/Assets.car',
        'Contents/Resources/Keylane.icns',
        'Contents/_CodeSignature/CodeResources',
    }
    for name in ('LICENSE', 'EmojiCatalog.tsv', 'Unicode-LICENSE.txt'):
        relative = f'Contents/Resources/{name}'
        expected.add(relative)
        source = ROOT / 'LICENSE' if name == 'LICENSE' else ROOT / 'Resources' / name
        if (app / relative).read_bytes() != source.read_bytes():
            raise SystemExit(f'Incorrect resource: {name}')
    contents = {str(path.relative_to(app)) for path in app.rglob('*') if path.is_file() or path.is_symlink()}
    if contents != expected:
        raise SystemExit(f'Unexpected or missing app contents: {contents ^ expected}')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info['CFBundleShortVersionString'] != version['version'] or info['CFBundleVersion'] != str(version['build']):
        raise SystemExit('Package version does not match version.json')
    if info['CFBundleIdentifier'] != 'org.keylane.launcher' or info['LSMinimumSystemVersion'] != '26.0':
        raise SystemExit('Unexpected bundle identity or deployment target')
    if info.get('CFBundleIconName') != 'Keylane' or info.get('CFBundleIconFile') != 'Keylane':
        raise SystemExit('Missing or incorrect application icon metadata')
    binary = app / 'Contents/MacOS/Keylane'
    if not os.access(binary, os.X_OK):
        raise SystemExit('Application executable permission missing')
    architectures = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip()
    if architectures not in ('arm64', 'x86_64') or image.name != f"Keylane-{version['version']}-macos-{architectures}.dmg":
        raise SystemExit(f'Filename/architecture mismatch: {architectures}')
    requirement = [DEVELOPER_ID_REQUIREMENT] if distribution else []
    subprocess.run(['codesign', '--verify', '--deep', '--strict', *requirement, str(app)], check=True)
    entitlement_data = subprocess.check_output(
        ['codesign', '-d', '--entitlements', '-', '--xml', str(app)], stderr=subprocess.DEVNULL)
    entitlements = plistlib.loads(entitlement_data) if entitlement_data else {}
    if not info.get('NSCameraUsageDescription') or entitlements.get('com.apple.security.device.camera') is not True:
        raise SystemExit('Missing camera usage description or entitlement')
    if distribution:
        if entitlements.get(APPLE_EVENTS_ENTITLEMENT) is not True:
            raise SystemExit('Distribution app is missing the Apple Events entitlement')
        subprocess.run(['spctl', '--assess', '--type', 'execute', '--verbose', str(app)], check=True)


def main():
    version = load_version()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--distribution', action='store_true', help='require Developer ID and an Apple notarization ticket')
    parser.add_argument('image', nargs='?', type=Path,
                        default=ROOT / 'dist' / f"Keylane-{version['version']}-macos-{platform.machine()}.dmg")
    args = parser.parse_args()
    image = args.image.resolve()
    if args.distribution:
        subprocess.run(['codesign', '--verify', DEVELOPER_ID_REQUIREMENT, str(image)], check=True)
        subprocess.run(['xcrun', 'stapler', 'validate', str(image)], check=True)
    with tempfile.TemporaryDirectory(prefix='keylane-package-') as temporary:
        mount = Path(temporary) / 'image'
        subprocess.run([
            'hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(image),
        ], check=True)
        try:
            shortcut = mount / 'Applications'
            if not shortcut.is_symlink() or os.readlink(shortcut) != '/Applications':
                raise SystemExit('DMG must contain a shortcut to /Applications')
            verify_app(mount / 'Keylane.app', image, version, args.distribution)
        finally:
            subprocess.run(['hdiutil', 'detach', str(mount)], check=True)
    print('DMG layout, app metadata, license, file inventory, architecture and signature: OK')


if __name__ == '__main__':
    main()
