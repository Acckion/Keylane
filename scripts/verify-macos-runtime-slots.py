#!/usr/bin/env python3
"""M0 second candidate: fixed signed slots, controlled spawn group and FD hygiene.

Diagnostic only; exit 2=blocked, 3=incomplete. No product/VM path is changed.
"""
import argparse
import contextlib
import errno
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import selectors
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / 'Tests/ExtensionPrototype/MacOSRuntimeM0'
spec = importlib.util.spec_from_file_location('m0', ROOT / 'scripts/verify-macos-runtime-m0.py')
m0 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m0)


def verdict(report):
    blockers = []
    for name in ['spawnSystem', 'spawnNode', 'childHostRead', 'hostRead', 'hostWrite', 'symlinkRead', 'network', 'inheritedDescriptor']:
        if report['slotA']['cases'][name]['allowed']:
            blockers.append(name)
    if report['slotB']['cases']['foreignSlotRead']['allowed']:
        blockers.append('crossSlotRead')
    if report['sameSlot']['cases']['foreignSlotRead']['allowed']:
        blockers.append('slotReuseResidue')
    for mode, record in report['lifecycle'].items():
        if not record['groupStopsTree']:
            blockers.append(mode + 'EscapesGroup')
    # No pass while the remaining original M0 obligations are untested.
    return ('blocked', blockers) if blockers else ('incomplete', [])


def snapshot(pid, expected):
    result = subprocess.run(['ps', '-ww', '-p', str(pid), '-o', 'stat=,pgid=,args='], capture_output=True, text=True, check=False)
    if result.returncode == 1 and not result.stdout.strip():
        return None
    if result.returncode != 0:
        raise RuntimeError('Cannot inspect owned process; refused to assume it exited')
    fields = result.stdout.strip().split(None, 2)
    if len(fields) != 3:
        raise RuntimeError('Incomplete owned process observation')
    if fields[0].startswith('Z'):
        return None
    if Path(fields[2].split(' ', 1)[0]).resolve() != expected.resolve():
        raise RuntimeError('Probe identity changed; refused cleanup')
    return int(fields[1])


@contextlib.contextmanager
def owned_directory():
    # Finder/Launch Services may create .DS_Store while signed fixture bundles
    # are removed. Retry ENOTEMPTY only, bounded and only for this mkdtemp root.
    task = Path(tempfile.mkdtemp(prefix='keylane-m0-slots-', dir='/private/tmp'))
    try:
        yield task
    finally:
        for attempt in range(3):
            try:
                shutil.rmtree(task)
                break
            except FileNotFoundError:
                break
            except OSError as error:
                if error.errno != errno.ENOTEMPTY or attempt == 2:
                    raise
                time.sleep(0.1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--archive', type=Path)
    args = parser.parse_args()
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        raise SystemExit('Requires arm64 macOS test host')
    if args.report.exists():
        raise SystemExit('Report already exists')
    identity = m0.resolve_identity()
    marker = uuid.uuid4().hex
    report = dict(schema=1, candidate='fixed-slots-posix-spawn', fixtureOnly=True, installed=False,
                  runtime=f'node-v{m0.VERSION}-darwin-arm64', archiveSHA256=m0.SHA256,
                  coverage={'keychain': 'not-tested', 'nativeAddon': 'not-tested',
                            'hostService': 'not-tested', 'forgedPeer': 'not-tested',
                            'fullSlotSanitization': 'not-tested', 'hostDeath': 'not-tested'})
    with owned_directory() as task:
        node = m0.download_node(task, args.archive)
        helper = task / 'helper'
        m0.run(['xcrun', 'clang', '-O2', '-framework', 'Foundation', str(FIXTURE / 'GroupHelper.m'), '-o', str(helper)])
        slots = []
        for name in ['a', 'b']:
            app = task / f'Slot-{name}.app'
            macos = app / 'Contents/MacOS'
            macos.mkdir(parents=True)
            shutil.copy2(node, macos / 'node')
            shutil.copy2(helper, macos / 'helper')
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
                CFBundleIdentifier=f'org.keylane.tests.runtime-m0.slot-{name}', CFBundleExecutable='helper',
                CFBundleName=f'Keylane M0 Slot {name}', CFBundlePackageType='APPL', LSUIElement=True)))
            for target, entitlements in [(macos / 'node', 'node.entitlements'), (app, 'helper.entitlements')]:
                m0.run(['codesign', '--force', '--options', 'runtime', '--timestamp=none', '--sign', identity,
                        '--entitlements', str(FIXTURE / entitlements), str(target)], capture_output=True)
                m0.verify_signature(target, identity, plistlib.loads((FIXTURE / entitlements).read_bytes()))
            slots.append((app, macos))
        host = task / 'host-owned'
        host.mkdir()
        secret = host / 'secret.txt'
        secret.write_text(marker)
        link = host / 'link'
        link.symlink_to(secret)
        control = task / 'control-home'
        control.mkdir()
        raw = os.open(secret, os.O_RDONLY)
        fd = fcntl.fcntl(raw, fcntl.F_DUPFD, 200)
        os.close(raw)
        os.set_inheritable(fd, True)
        template = (FIXTURE / 'probe.cjs').read_text()
        env = {'PATH': '/usr/bin:/bin', 'KEYLANE_M0_CONTAINER': str(control)}
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen(8)
            config = dict(secret=str(secret), link=str(link), marker=marker, output=str(host / 'output'),
                          port=listener.getsockname()[1], containerName=f'.keylane-slot-{marker}',
                          previousName=f'.keylane-slot-{marker}', mode='slotWrite', probeFD=fd)
            def invoke(command, config):
                p = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     text=True, env=env, start_new_session=True, pass_fds=(fd,))
                try:
                    out, _ = p.communicate(template.replace('CONFIG_PLACEHOLDER', json.dumps(config)), timeout=15)
                    if p.returncode != 0:
                        raise RuntimeError(f'Probe failed: {p.returncode}')
                    return json.loads(out)
                finally:
                    if p.poll() is None:
                        os.killpg(p.pid, signal.SIGKILL)
                    p.wait(timeout=5)
            try:
                baseline = invoke([str(node), '--max-old-space-size=64', '-'], config)
                for name in ['hostRead', 'hostWrite', 'symlinkRead', 'network', 'childHostRead', 'inheritedDescriptor']:
                    if not baseline['cases'][name]['allowed']:
                        raise RuntimeError('Invalid positive control: ' + name)
                a = invoke([str(slots[0][1] / 'helper')], config)
                target = a.pop('fixturePath')
                # A owns a verified existing marker. B attempts that exact path;
                # never enumerate or inspect unrelated container contents.
                b = invoke([str(slots[1][1] / 'helper')], dict(config, mode='slotCheck', slotTarget=target))
                same = invoke([str(slots[0][1] / 'helper')], dict(config, mode='slotCheck', slotTarget=target))
                if not same['cases']['foreignSlotRead']['allowed']:
                    raise RuntimeError('Same-slot marker control failed')
                report.update(control=baseline, slotA=a, slotB=b, sameSlot=same)
            finally:
                # Remove only this run's markers from their owning helper slots.
                for _, macos in slots:
                    cleaned = invoke([str(macos / 'helper')], dict(config, mode='slotClean'))
                    if not cleaned['cases']['markerCleanup']['allowed']:
                        raise RuntimeError('Slot marker cleanup failed')
                os.close(fd)
        ambient = subprocess.run([str(slots[0][1] / 'helper')], input='', text=True, capture_output=True, env=env, timeout=5)
        if ambient.returncode != 78:
            raise RuntimeError('Helper accepted an ambient host process group')
        report['ambientGroupRejected'] = True
        report['lifecycle'] = {}
        for mode in ['hang', 'detached']:
            macos = slots[0][1]
            p = subprocess.Popen([str(macos / 'helper')], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, text=True, env=env, start_new_session=True)
            children = []
            try:
                p.stdin.write(template.replace('CONFIG_PLACEHOLDER', json.dumps(dict(config, mode=mode))))
                p.stdin.close()
                with selectors.DefaultSelector() as poller:
                    poller.register(p.stdout, selectors.EVENT_READ)
                    if not poller.select(timeout=8):
                        raise RuntimeError('Lifecycle probe not ready')
                    ready = json.loads(p.stdout.readline())
                children = [ready['pid'], ready['descendant']]
                groups = [snapshot(pid, macos / 'node') for pid in children]
                os.killpg(p.pid, signal.SIGKILL)
                p.wait(timeout=5)
                deadline = time.monotonic() + 1
                while any(snapshot(pid, macos / 'node') is not None for pid in children) and time.monotonic() < deadline:
                    time.sleep(0.05)
                record = dict(nodeSharesHelperGroup=groups[0] == p.pid, descendantSharesHelperGroup=groups[1] == p.pid,
                              groupStopsTree=all(snapshot(pid, macos / 'node') is None for pid in children))
                report['lifecycle'][mode] = record
            finally:
                # A detached probe deliberately escapes the group. It is still a
                # known first-party process, not a production discovery strategy.
                for pid in children:
                    if snapshot(pid, macos / 'node') is not None:
                        os.kill(pid, signal.SIGKILL)
                if p.poll() is None:
                    os.killpg(p.pid, signal.SIGKILL)
                p.wait(timeout=5)
                deadline = time.monotonic() + 3
                while any(snapshot(pid, macos / 'node') is not None for pid in children) and time.monotonic() < deadline:
                    time.sleep(0.05)
                if any(snapshot(pid, macos / 'node') is not None for pid in children):
                    raise RuntimeError('Known probe process cleanup failed')
                report['lifecycle'].setdefault(mode, {})['fixtureCleanupConfirmed'] = True
        for app, macos in slots:
            for target, entitlements in [(macos / 'node', 'node.entitlements'), (app, 'helper.entitlements')]:
                m0.verify_signature(target, identity, plistlib.loads((FIXTURE / entitlements).read_bytes()))
        report['signaturesVerifiedBeforeAndAfter'] = True
        for key in ['control', 'slotA', 'slotB', 'sameSlot']:
            report[key].pop('pid', None)
            report[key].pop('fixturePath', None)
        report['gate'], report['blockers'] = verdict(report)
    report['temporaryArtifactsRemoved'] = True
    args.report.parent.mkdir(parents=True, exist_ok=True)
    with args.report.open('x') as output:
        json.dump(report, output, indent=2)
    print(json.dumps(dict(gate=report['gate'], blockers=report['blockers'], report=str(args.report))))
    return 2 if report['gate'] == 'blocked' else 3


if __name__ == '__main__':
    raise SystemExit(main())
