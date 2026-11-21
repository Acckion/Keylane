#!/usr/bin/env python3
"""First-party macOS sandbox feasibility experiment; never installs an app.

Exit 2 means the report contains isolation blockers; exit 3 means coverage is
incomplete. A report alone never authorizes production execution or M1.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import selectors
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / 'Tests/ExtensionPrototype/MacOSRuntimeM0'
VERSION = '24.12.0'
ARCHIVE = f'node-v{VERSION}-darwin-arm64.tar.gz'
SHA256 = '319f221adc5e44ff0ed57e8a441b2284f02b8dc6fc87b8eb92a6a93643fd8080'


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def download_node(directory, cached_archive=None):
    archive = cached_archive or directory / ARCHIVE
    if cached_archive is None:
        with urllib.request.urlopen(f'https://nodejs.org/dist/v{VERSION}/{ARCHIVE}', timeout=60) as response:
            with archive.open('wb') as output:
                shutil.copyfileobj(response, output, length=1024 * 1024)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise RuntimeError('Official runtime archive digest mismatch')
    with tarfile.open(archive) as package:
        name = f'node-v{VERSION}-darwin-arm64/bin/node'
        member = package.getmember(name)
        if not member.isfile():
            raise RuntimeError('Node executable is not a regular archive member')
        with package.extractfile(member) as source, (directory / 'node').open('wb') as output:
            shutil.copyfileobj(source, output)
        # Keep the upstream license alongside the temporary runtime, not in git.
        license_member = package.getmember(f'node-v{VERSION}-darwin-arm64/LICENSE')
        with package.extractfile(license_member) as source:
            (directory / 'NODE-LICENSE').write_bytes(source.read())
    (directory / 'node').chmod(0o755)
    return directory / 'node'


def verify_signature(path, identity, expected_entitlements):
    run(['codesign', '--verify', '--strict', str(path)], capture_output=True)
    raw = run(['codesign', '-d', '--entitlements', ':-', str(path)], capture_output=True).stdout
    entitlements = plistlib.loads(raw)
    if entitlements != expected_entitlements:
        raise RuntimeError('Signed entitlements differ from declared fixture')
    detail = run(['codesign', '-dv', '--verbose=4', str(path)], capture_output=True).stderr.decode()
    if 'Authority=Apple Development:' not in detail or 'flags=0x10000(runtime)' not in detail:
        raise RuntimeError('Apple Development / Hardened Runtime signature missing')
    # Verify against a requirement containing the selected certificate digest.
    requirement = f'anchor apple generic and certificate leaf = H"{identity}"'
    run(['codesign', '--verify', '--strict', '-R=' + requirement, str(path)], capture_output=True)


REQUIRED_COVERAGE = {'keychain', 'nativeAddon', 'hostService', 'descriptorLeak', 'forgedPeer', 'sharedContainer', 'childSandboxInheritance', 'ownedTreeCancellation', 'abnormalExit'}


def classify(first, second, coverage):
    blockers = [name for name in ['hostRead', 'hostWrite', 'symlinkRead', 'network', 'spawnSystem', 'spawnNode', 'childHostRead']
                if first['cases'][name]['allowed']]
    if second['cases']['crossInvocationRead']['allowed']:
        blockers.append('sharedContainer')
    if blockers:
        return 'blocked', blockers
    # M0 must never go green just because a subset of probes passed.
    if any(coverage.get(key) != 'tested' for key in REQUIRED_COVERAGE):
        return 'incomplete', []
    return 'passed', []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--archive', type=Path, help='Reuse the official archive; the pinned digest is still mandatory')
    args = parser.parse_args()
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        raise SystemExit('M0 currently supports only an isolated arm64 macOS test host')
    if args.report.exists():
        raise SystemExit('Refusing to overwrite an existing experiment report')
    # Resolve existing credentials without creating/changing the repository pin.
    sys.path.insert(0, str(ROOT / 'scripts'))
    import signing
    pin = signing.PIN.read_text().strip() if signing.PIN.exists() else ''
    if not pin and not os.environ.get('KEYLANE_SIGNING_IDENTITY'):
        listing = run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True).stdout
        import re
        matches = re.findall(r'([A-Fa-f0-9]{40})\s+"Apple Development:[^"]+"', listing)
        if len(matches) != 1:
            raise SystemExit('Set KEYLANE_SIGNING_IDENTITY to an existing Apple Development identity')
        os.environ['KEYLANE_SIGNING_IDENTITY'] = matches[0]
    identity = signing.signing_identity(require_apple_development=True)
    marker = uuid.uuid4().hex
    result = dict(schema=1, runtime=f'node-v{VERSION}-darwin-arm64', archiveSHA256=SHA256,
                  fixtureOnly=True, installed=False, gate='not-evaluated', cases={},
                  coverage={'keychain': 'not-tested', 'nativeAddon': 'not-tested', 'hostService': 'not-tested',
                            'descriptorLeak': 'not-tested', 'forgedPeer': 'not-tested'})
    with tempfile.TemporaryDirectory(prefix='keylane-macos-m0-', dir='/private/tmp') as temporary:
        task = Path(temporary)
        node = download_node(task, args.archive)
        app = task / 'KeylaneM0.app'
        macos = app / 'Contents/MacOS'
        macos.mkdir(parents=True)
        shutil.copy2(node, macos / 'node')
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
            CFBundleIdentifier='org.keylane.tests.runtime-m0', CFBundleExecutable='helper',
            CFBundleName='Keylane M0 Probe', CFBundlePackageType='APPL', LSUIElement=True)))
        run(['swiftc', '-O', str(FIXTURE / 'Helper.swift'), '-o', str(macos / 'helper')])
        for target, entitlements in [(macos / 'node', 'node.entitlements'), (app, 'helper.entitlements')]:
            run(['codesign', '--force', '--options', 'runtime', '--timestamp=none', '--sign', identity,
                 '--entitlements', str(FIXTURE / entitlements), str(target)], capture_output=True)
        verify_signature(app, identity, plistlib.loads((FIXTURE / 'helper.entitlements').read_bytes()))
        verify_signature(macos / 'node', identity, plistlib.loads((FIXTURE / 'node.entitlements').read_bytes()))
        host = task / 'host-owned'
        host.mkdir()
        secret = host / 'secret.txt'
        secret.write_text(marker)
        link = host / 'link'
        link.symlink_to(secret)
        control_home = task / 'control-home'
        control_home.mkdir()
        template = (FIXTURE / 'probe.cjs').read_text()
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen(8)
            config = dict(secret=str(secret), link=str(link), marker=marker, output=str(host / 'output.txt'),
                          port=listener.getsockname()[1], containerName=f'.keylane-m0-{marker}-a',
                          previousName=f'.keylane-m0-{marker}-a', mode='write')
            def probe(executable, config):
                code = template.replace('CONFIG_PLACEHOLDER', json.dumps(config))
                start = time.monotonic()
                p = subprocess.Popen(executable, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     text=True, start_new_session=True, env={'PATH': '/usr/bin:/bin', 'KEYLANE_M0_CONTAINER': str(control_home)})
                try:
                    stdout, stderr = p.communicate(code, timeout=15)
                    if p.returncode != 0:
                        raise RuntimeError(f'Fixture exit {p.returncode}; stderr withheld (contains only synthetic test data)')
                    record = json.loads(stdout)
                    record['elapsedMs'] = round((time.monotonic() - start) * 1000, 1)
                    return record
                finally:
                    try:
                        os.killpg(p.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    p.wait(timeout=5)
            # Positive control uses the same official Node and synthetic paths,
            # without inherited sandbox entitlements or permissions/shims.
            control = probe([str(node), '--max-old-space-size=64', '-'], config)
            for name in ['hostRead', 'hostWrite', 'symlinkRead', 'network', 'spawnSystem', 'spawnNode', 'childHostRead', 'jit']:
                if not control['cases'][name]['allowed']:
                    raise RuntimeError(f'Invalid positive control: {name}')
            first = probe([str(macos / 'helper')], config)
            config.update(mode='read', containerName=f'.keylane-m0-{marker}-b')
            second = probe([str(macos / 'helper')], config)
            result['cases'] = dict(control=control, sandboxFirst=first, sandboxSecond=second)
            result['coverage']['sharedContainer'] = 'tested'
            result['coverage']['childSandboxInheritance'] = 'tested'
            # Exercise an owned process tree; the production supervisor is not implemented yet.
            code = template.replace('CONFIG_PLACEHOLDER', json.dumps(dict(config, mode='hang')))
            p = subprocess.Popen([str(macos / 'helper')], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, text=True, start_new_session=True,
                                 env={'PATH': '/usr/bin:/bin'})
            children = []
            owned_groups = set()
            def live_owned():
                alive = []
                for pid in children:
                    snapshot = subprocess.run(['ps', '-ww', '-p', str(pid), '-o', 'stat=,pgid=,args='], capture_output=True, text=True)
                    if snapshot.returncode != 0:
                        continue
                    fields = snapshot.stdout.strip().split(None, 2)
                    if len(fields) != 3 or fields[0].startswith('Z'):
                        continue
                    if Path(fields[2].split(' ', 1)[0]).resolve() != (macos / 'node').resolve() or int(fields[1]) not in owned_groups:
                        raise RuntimeError('Owned probe identity changed; refused cleanup')
                    alive.append((pid, int(fields[1])))
                return alive
            try:
                p.stdin.write(code)
                p.stdin.close()
                with selectors.DefaultSelector() as selector:
                    selector.register(p.stdout, selectors.EVENT_READ)
                    if not selector.select(timeout=8):
                        raise RuntimeError('Hang fixture never became ready')
                    ready = json.loads(p.stdout.readline())
                children = [ready['pid'], ready['descendant']]
                owned_groups = {os.getpgid(pid) for pid in children}
                start = time.monotonic()
                os.killpg(p.pid, signal.SIGKILL)
                p.wait(timeout=5)
                deadline = time.monotonic() + 1
                while live_owned() and time.monotonic() < deadline:
                    time.sleep(0.05)
                result['lifecycle'] = dict(helperGroupStopsTree=not live_owned(), elapsedMs=round((time.monotonic() - start) * 1000, 1))
            finally:
                # Do not signal already-dead groups (macOS may retain zombies),
                # nor a PID whose executable/group no longer matches this fixture.
                for group in {group for _, group in live_owned()}:
                    try:
                        os.killpg(group, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                if p.poll() is None:
                    p.kill()
                p.wait(timeout=5)
                deadline = time.monotonic() + 3
                while live_owned() and time.monotonic() < deadline:
                    time.sleep(0.05)
                if live_owned():
                    raise RuntimeError('Owned probe cleanup could not be confirmed')
                result.setdefault('lifecycle', {})['fixtureCleanupConfirmed'] = True
            abnormal = subprocess.run([str(macos / 'helper')],
                input=template.replace('CONFIG_PLACEHOLDER', json.dumps(dict(config, mode='abnormal'))),
                text=True, capture_output=True, timeout=10, env={'PATH': '/usr/bin:/bin'})
            if abnormal.returncode != 42:
                raise RuntimeError('Helper failed to propagate abrupt Node exit')
            result['lifecycle']['abnormalExitPropagated'] = True
            result['coverage']['ownedTreeCancellation'] = 'tested'
            result['coverage']['abnormalExit'] = 'tested'
            result['gate'], result['blockers'] = classify(first, second, result['coverage'])
            if not result['lifecycle']['helperGroupStopsTree']:
                result['gate'] = 'blocked'
                result['blockers'].append('helperGroupDoesNotStopTree')
            # No production pass is emitted while any mandatory M0 coverage is missing.
        verify_signature(app, identity, plistlib.loads((FIXTURE / 'helper.entitlements').read_bytes()))
        verify_signature(macos / 'node', identity, plistlib.loads((FIXTURE / 'node.entitlements').read_bytes()))
        result['signaturesVerifiedBeforeAndAfter'] = True
    args.report.parent.mkdir(parents=True, exist_ok=True)
    with args.report.open('x') as output:
        json.dump(result, output, indent=2)
    print(json.dumps({'gate': result['gate'], 'blockers': result.get('blockers'), 'report': str(args.report)}))
    return {'blocked': 2, 'incomplete': 3, 'passed': 0}[result['gate']]


if __name__ == '__main__':
    raise SystemExit(main())
